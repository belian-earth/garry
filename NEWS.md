# garry (development version)

## New features

* `lazy_dataset()` reads N-D arrays such as a `(time, band, y, x)` Zarr
  array (`ZARR:"<store>":/<array>`) as dataset bands by time slice, using
  the dimension tags GDAL puts on each band; `bands` indexes the band
  dimension. A bare `ZARR:"https://..."` store is read over `/vsicurl/`.
* `lazy_dataset()` over several Zarr arrays in different CRSs (one per UTM
  zone, as OlmoEarth stores them) mosaics them onto the target grid: each
  window warps every zone and every band of a slice in one pass, the later
  source winning where zones overlap.
* `time_sel()` takes a dataset and keeps the matching slices of every band.
* `dequantize_signed_power()` decodes signed-power Int8 embeddings, and
  `dequantize_olmoearth()` decodes the OlmoEarth v1.3 embeddings (the
  same scheme as `dequantize_aef()`).
* `extract_points()` reads a materialised `(band, y, x)` cube, one column
  per band.
* New vignette: OlmoEarth embeddings from Zarr.

## Performance

* The bands of one file collapse into a single read per window when the
  file's bands share storage (a Zarr array, a pixel-interleaved file),
  also through a warp onto a target grid and through `lazy_map()` applied
  per band. A pooled read of a 128-band OlmoEarth window fetched 11 times
  its bytes before (102 s for 1024 x 1024 pixels) and fetches them once
  now (14 s). Band-interleaved files keep their per-band reads.
* A Zarr dataset handle is closed once it has read `garry.zarr_handle_mb`
  (256 MB), and daemons close their Zarr handles between runs, since GDAL
  keeps every chunk it decodes for the life of the handle.
* A Zarr store on a reprojected grid warps window by window from its
  cached handle rather than through a warped VRT, which reopened the store
  inside GDAL for every read.

## Bug fixes

* Read daemons can open Zarr v3 stores: the vsicurl allowlist admits
  `zarr.json` and extensionless chunk keys.
* Reads that touch a Zarr store no longer turn on GDAL's worker threads.
  GDAL reports from those threads, and gdalraster's message handler then
  calls into R off the main thread, which aborted the R session.
* `garry_gdal_config()` no longer sets `GDAL_HTTP_RETRY_CODES`. GDAL
  matches that list by substring, so `"500"` made every curl failure
  (DNS included) retry with backoff for minutes; GDAL's default set is the
  same codes plus timeouts and resets.
* `g_mean()` averages integer input at f32, in custom reducers and
  `lazy_map()` functions alike. anvl 0.5.1 summed an integer input in its
  own dtype, so a mean of Int8 or Int16 values wrapped (100 and 120 gave
  -4.5).

# garry 0.1.0

The first stable-track release. The API below is the one garry intends to
keep; it remains marked experimental while it settles.

## Installation

* garry's XLA stack (anvl >= 0.5.1, pjrt, stablehlo, xlamisc) is installed
  from the r-xla r-universe, and gdalraster from CRAN (>= 2.7.0). Point pak
  at the universe first:
  `options(repos = c(rxla = "https://r-xla.r-universe.dev", getOption("repos")))`.
* R >= 4.4 is required, as anvl and pjrt require it.

## Breaking changes

* Verbs that shared names with terra and raster generics are renamed:
  `align()` is `align_to()`, `mask()` is `apply_mask()`, `focal()` is
  `focal_map()` and `draw()` is `plan_draw()`. The grid accessors `xmin()`,
  `ymin()`, `xmax()`, `ymax()` and `res()` are replaced by `grid_bbox()` and
  `grid_res()`, joined by `grid_crs()`.
* `align_to()` defaults to `resampling = "near"` (was `"bilinear"`), as the
  readers do, so categorical and QA rasters keep their values. Pass
  `"bilinear"` or `"average"` for continuous data.
* `kalman_llt()` takes `dtype` (was `out_dtype`), like `kalman_smooth()`;
  `extract_points()` takes `x` (was `raster`) as its first argument.
* `reduce_over()` accepts only the reducers that execute: `"sum"`, `"mean"`,
  `"min"`, `"max"`, `"median"` and `"count"`. `"prod"`, `"quantile"`, `"sd"`,
  `"var"`, `"any"` and `"all"` were documented but failed at `collect()`;
  they now fail when the node is built (tracked in #32).
* `lazy_stac_stack()` is removed; `lazy_dataset()` builds the same stacks.
* Engine internals are no longer exported: the daemon task bodies, the
  low-level GDAL adapter (`gdal_read_window()`, `gdal_write_window()`,
  `gdal_create_output()`, `gdal_warp_vrt()`), bridge plumbing (`g_jit()`,
  `g_quantize()`, raw transport), `as_vaster_extent()`, and the unused
  `fusable()`, `is_barrier()`, `FusedNode` and `cross_grid_window()`.
* Declared dtypes follow what the kernels compute. A double scalar makes an
  integer raster f32 (`x * 0.5`, `x - 100`); an integer scalar (`2L`) keeps
  it. Sums of 8- and 16-bit integers accumulate in i32 (u32 in i64), where
  they previously wrapped.
* Comparisons return `NaN` where an operand is nodata, not a valid 0, so a
  `nan_rm` reduction of a mask skips nodata.
* `focal_map()`, `focal_kernel()` and `lazy_patch()` read integer input as
  f32, so cells beyond the raster edge are `NaN`; their output is f32.
* A band reduction (`reduce_over(ds, op, "band")`) and a dataset scan
  default to the value bands, leaving the QA band out.
* With regime boundaries, the Kalman smoother returns `NaN` for a regime with
  no observation instead of the previous regime's extrapolation.

## New features

* Base accessors for lazy objects: `dim()`, `names()`, `length()`, `$` and
  `$<-`, and `time_labels()`.
* Unary `-` and `+`, `!`, `&` and `|` (on 0/1 masks), logical scalars, and
  `round(x, digits)` on lazy rasters. `sum(x)` and other summaries point at
  `reduce_over()`.
* `g_round()` and `g_clamp()` join the documented `g_*` vocabulary.
* `kalman_smooth()` gains `bands` for datasets.
* Collected results record their band names, which `as_terra()` uses.
* A small example raster ships in `inst/extdata`; the core verbs have
  runnable examples.

## Performance

Small local jobs no longer pay for the engine built for large remote ones.
On the kadyb/raster-benchmark Landsat scene (10 bands of 7771 x 7871
UInt16), single-threaded:

* Plans that only read (sources, warps of them, and band or time stacks)
  take a new `"read_only"` route: each chunk is copied from GDAL straight
  into the result, or into the output file. In-process, local files decode
  on every core. With pools running, the read pool reads the chunks in
  parallel; collected chunks are copied into place as they land, and
  written ones pass through shared memory to the writer daemon, so
  compression overlaps the reads. Loading the scene drops from 30.5 s to 5.1 s, a crop from
  5.6 s to 1.3 s, a 3x downsample from 6.7 s to 1.9 s and a write from
  40.1 s to 6.4 s (3.8 s with pools). Values and files are identical to the compute path;
  `options(garry.read_only = FALSE)` turns the route off.
* User `creation_options` keep multi-threaded compression unless they set
  `NUM_THREADS`.
* Window reads finish in C (nodata, scale and offset, and the transpose to
  R's column order), with the same double values: an NDVI drops from
  3.8 s to 1.9 s.

## Bug fixes

Wrong results:

* Two reads of one file that differed in scale, offset or resampling were
  merged into one.
* `materialise()` kept only band 1 of a band or time stack, and refused
  integer plans.
* South-up rasters (AEF embeddings) were read upside down on unwarped paths.
* A nodata value declared by the user, not the file, leaked into warps.
* Re-reading a rewritten file returned the old pixels from a cached handle.
* The composite fast path computed every band with band 1's function and
  mask chain.
* `extract_points()` ignored band selection, nodata and scale/offset.
* `ds[[name]] <-` with band math broke multi-slice datasets.
* `align_to()` onto a stacked target declared a grid it did not produce.
* `stac_query()` excluded the last day of the search range.
* `stac_sign_mpc()` signed every item with the first collection's token.
* `preview()` swapped explicitly chosen bands and dropped scale/offset.
* `qa_bits()` let a repeated bit carry into the next one.
* `time_sel()` ignored prefix selectors when any selector matched exactly.
* Integer focal edges were computed from zeros instead of nodata.
* Gradients skipped NaN only at stage inputs and read sources
  nearest-neighbour regardless of their resampling.
* Quantized writes to unsigned dtypes failed, and saturated values could
  collide with nodata.
* Building the OmniCloudMask EdgeNeXt weights from scratch failed.

Failures and hangs:

* A dead compute daemon made every later `collect()` hang; runs now fail
  fast with a `garry_pool_error`.
* A failed writer close (a full disk at the final flush) reported success.
* A failed write left a half-written file at the destination.
* `write_tif(cog = TRUE)` on grouped datasets overwrote files and leaked
  temporaries; `{group}` in a directory component failed.
* Integer overflows in the composite route and the chunk-snapping LCM
  aborted large plans.
* `plan_draw()` was exponential in shared subgraphs.
* Distributed runs drew their run id from the user's RNG stream.
* The cgroup memory probe ignored ancestor limits and counted page cache
  as used, throttling confined runs to one task at a time.
