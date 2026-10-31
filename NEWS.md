# garry (development version)

## Breaking changes

* A `garry.*` option with no such name aborts with a `garry_option_error`,
  at run start and at `garry_daemons()`, so a typo or a retired name no
  longer means the default.
* These options are gone, and setting one now aborts:
  `garry.compute_inflight`, `garry.compute_ram_fraction`,
  `garry.cost_comp_efficiency`, `garry.cost_gflops_core`,
  `garry.cost_shm_bw_mbs`, `garry.cost_xla_client_mb`,
  `garry.fuse_flops_max`, `garry.fuse_reader_mb`, `garry.fuse_tile_mb`,
  `garry.gd_compute_budget`, `garry.gd_parallel`, `garry.jit_warmup`,
  `garry.scan_strip_px`, `garry.shm_headroom_mb`, `garry.warp_dedup` and
  `garry.window_margin`. Their defaults hold, the figures as named
  constants, and `garry_options()` has no calibration tier.
  `garry.ram_budget_mb` now also sets a fused kernel's tile budget, and
  `garry.exec_ram_fraction` also caps the fetch-ordered pipeline.
* `stac_sign_mpc()` loses `subscription_key`: the key comes from
  `MPC_TOKEN`, which the re-sign of a long run read anyway, so a key
  passed by argument went missing on re-sign.
* `garry.handle_cache_max`, `garry.zarr_handle_mb` and
  `garry.daemon_gc_mb` are gone. No broadcast carried the first two to the
  daemons and the third reached them on one route only, so a host setting
  did nothing where it mattered. `read_handles` still sets the read pool's
  handle depth.
* `garry.exec_stats` and the `garry_exec_stats` attribute it set are gone.
* `garry.read_fail` is gone, with its `"nodata"` holes: nothing used it,
  and on a daemon its warning went nowhere, so a run finished with holes
  and no trace. A failed read or fetch always aborts, as a
  `garry_read_error` on the host and inside the `garry_task_error` of a
  daemon task, naming the file and GDAL's cause. A signed URL's query
  string stays out of the message.
* These arguments are gone: `focal_map(boundary)`, `focal_kernel(boundary)`
  and the `FocalNode` property of that name, `coarsen(fun)`,
  `fill_gaps(over)`, `apply_mask(drop)`, `lazy_dataset(lon, sort_field)`,
  `grid_from_bbox(ellps, dtype)`, `grid_from_src(ellps, dtype)`,
  `grid_equal(tol)`, `grid_diff(tol)`, `stac_query(limit)`,
  `stage_raw_cube(slab_rows)`, `geomedian(eps)`, `medoid(eps)`,
  `kalman_llt(kappa)`, `g_scan(length)`, `garry_explain_placement(mode)`
  and `garry_daemons(...)`. Each behaves as its default did. Positional
  calls shift: `bands` is now `focal_map()`'s fourth argument, and in
  `lazy_dataset()` `nodata` follows `granularity`, then `resampling`.
  `g_scan()` requires `xs`. `.g_has_raw_upload()` is no longer exported.
* `lazy_map(dtype = )` holds inside a stage as it does across one, so a
  map's consumers read the cast value wherever the planner splits them.
  A kernel that narrowed to an integer dtype and fed a map in its own
  stage saw the uncast float before; those values change.
* Invalid arguments abort where they are given. `lazy_dataset()` refuses
  `bands` that are not whole positions, each once, and on files it
  refuses `granularity` and more than one `mask_asset`. `lazy_source()`
  refuses a `band` that is not a whole number from 1, and
  `stac_time_slices()` refuses `lon` without `"solar_day"`.
  `reduce_over(nan_rm = )` must be `TRUE` or `FALSE`;
  `shrink_footprint(radius = )`, `apply_mask(open = , dilate = )` and
  `garry.gd_strips` must be whole numbers; a write's `band_names` must
  match its bands.
* `write_tif()` takes `cog` as `TRUE` or `FALSE` alone, and refuses
  `overview_resampling` without `cog = TRUE`. `collect()` takes
  `distributed` as `TRUE` or `FALSE` alone.

## New features

* `coarsen(x, factor)` maps a read onto the grid `factor` times coarser
  by block means of its valid values. Its read assembles each window's
  finer cells from the sources as their nearest-neighbour read does
  (direct window reads of the sources on those cells' pixels, a warp of
  each other source alone, later sources winning where they hold data),
  decodes them if the dataset decodes, and averages each block in one
  pass. `stack_bands(coarsen(lazy_dataset(tiles, grid10, resampling =
  "near", decode = dequantize_aef), 3L))` builds a 30 m embedding cube
  straight from the tiles, identical to writing the 10 m codes and then
  averaging their decoded values: an AEF box-year (four south-up tiles,
  64 bands, 4488 x 5727 codes) in 8.5 s instead of 14 s through the
  codes (about 36 s before this release), an OlmoEarth window (128
  bands, through a false-origin shift) in 6.8 s instead of 9.7 s.
  Cells warped from a reprojected source match the 10 m read's under
  `garry.warp_exact = TRUE`.
* `lazy_dataset(decode = )` takes several sources and Zarr arrays, one
  lookup-table VRT each.
* `lazy_dataset(decode = )` decodes a file's 8-bit codes before any
  resampling: each code goes through a table made by evaluating the
  decode (for example `dequantize_aef()`) on every code, the nodata code
  becoming NaN, and `resampling = "average"` then takes the mean of the
  valid decoded values. This replaces the lookup-table VRT a caller
  built to average decoded embeddings. Every read takes the codes at
  full resolution, never an overview's resampled codes. Aligned reads,
  south-up files included, decode the codes themselves: a 30 m cube of
  a 64-band AEF box-year (codes 4488 x 5727 px) wrote in 4.0 s instead
  of 19 s through the lookup-table VRT, and a 128-band OlmoEarth one
  in 2.4 s instead of 12.6 s. The two agree to f32 rounding: 0.6% of
  OlmoEarth cells differ, by at most 6e-8 (GDAL averages in an order
  garry does not reproduce). A `mask_asset` band is read as stored, and
  bands must share one nodata code.
* `lazy_dataset()` reads N-D arrays such as a `(time, band, y, x)` Zarr
  array (`ZARR:"<store>":/<array>`) as dataset bands by time slice, using
  the dimension tags GDAL puts on each band; `bands` indexes the band
  dimension. A bare `ZARR:"https://..."` store is read over `/vsicurl/`.
* `lazy_dataset()` over several Zarr arrays (one per UTM zone, as
  OlmoEarth stores them) mosaics them onto the target grid: each window
  warps every zone and every band of a slice in one pass, the later source
  winning where zones overlap. The arrays must agree on their bands and
  dimension coordinates.
* `band_sel()`, `time_sel()` and per-slice operations work on a stack after
  it has been collected (the planner rewrites collected stacks in place).
* `time_sel()` takes a dataset and keeps the matching slices of every band.
* `lazy_dataset(time = )` builds only the selected time slices of an N-D
  source, selected as `time_sel()` selects them. A 9-year, 128-band
  OlmoEarth store built 1152 band reads (about 2 s) before `time_sel()`
  kept 128; with `time = "2024"` it builds those 128 (0.25 s).
* `dequantize_signed_power()` decodes signed-power Int8 embeddings, and
  `dequantize_olmoearth()` decodes the OlmoEarth v1.3 embeddings (the
  same scheme as `dequantize_aef()`).
* `extract_points()` reads a materialised `(band, y, x)` cube, one column
  per band.
* New vignette: OlmoEarth embeddings from Zarr.

## Performance

* Compute kernels reach daemons as StableHLO programs: the host traces
  each kernel once per input shape, a daemon compiles the text, and no R
  closure crosses a process. Compute stages on one chunk fold into one
  program where the task overhead saved beats the compile. A fixture of
  hutan's SI tail, 3,225 tasks, went from 34.6 s cold and 44.7 s warm,
  peaking at 7,117 MB, to 18.1 s and 11.9 s at 5,360 MB, with every
  output hash matching. The GPU device and the composite and reduce
  routes keep closures. `garry.kernel_wire = "closure"` and
  `garry.stage_merge = "guarded"` are the switches back. A kernel that
  meets inputs its plan did not list fails with a
  `garry_no_program_error`.
* A program set holds each constant once, as raw bytes, and a daemon
  keeps one device buffer per constant and drops its R copy. Warm-up
  compiles a kernel's modal shape only; other shapes compile where a task
  first meets them. A stage's signature is computed once a run.
* One `fn` over a dataset's bands or groups traces once. A GTI sidecar is
  read once until it changes.

* Every kernel goes through one cache at one cap, on the daemons and on
  the host. The host kernels of the composite and reduce routes now reuse
  their compile from run to run, as the single-process route's do, and a
  band kernel's key no longer changes with a function's source reference
  or byte code, which recompiled it on every rebuilt plan and split leaf
  reduces sharing a mask into separate pipelines.
* A nearest-neighbour read of several sources no mosaic VRT can hold
  (south-up tiles, tiles in a neighbouring projection, one Zarr array per
  UTM zone) goes source by source: a direct window read of each source
  that lies on the target grid's pixels, and a warp of each other source
  alone, laid over the window in order with later sources winning where
  they hold data, the cells the warper gives them all together. Only the
  sources off the target's pixels pay for warping. Masked sources, and
  float sources whose nodata is not NaN where they overlap, keep the
  warper. A single south-up file read onto a subset of its own pixels is
  a direct read too, and south-up rows flip in C. One box-year of four
  south-up 64-band tiles (4488 x 5727 px) fetched to Int8 in 10 s
  instead of 17 s with 8 readers, identical to gdalwarp's result; two
  4-band tiles in neighbouring UTM zones, one on the target's pixels, in
  1.05 s instead of 1.13 s.
* Scan stages run faster. On hutan's SI tail at 5.76 M cells, with the
  daemon changes below, the robust Kalman smoother stage went from 0.66 s
  to 0.41 s a chunk and the drain from 44 s to 38 s with two compute
  daemons (34 s to 30 s with six); the products are identical. Three
  changes:
  * `g_median()` takes a median over one short axis (up to 32 values) with
    a sorting network, a fixed sequence of elementwise minima and maxima,
    instead of anvl's transpose and per-pixel sort: 6x faster for 13
    values, with identical results. `kalman_llt()`'s robust passes,
    `hampel_smooth()` and `reduce_over(x, "median")` use it.
  * A compute stage holding a scan runs its kernel over row strips of
    about 4,000 cells inside one XLA program. XLA
    runs each scan step as passes over whole f64 planes, so on a full chunk
    the kernel was bound by memory bandwidth (six cores ran it 2.1x faster
    than one); a strip's planes stay in cache. The smoother stage took
    0.28 s a 480 x 480 chunk in strips on one core, against 0.71 s whole on
    one core and 0.34 s on six.
  * `kalman_llt()`'s backward pass recomputes the predicted state from the
    filtered one rather than storing five more f64 cubes.
* Edge chunks run their stage's modal kernel. A grid that is not a
  multiple of the chunk size has right, bottom and corner chunks of three
  more shapes, and XLA compiles a kernel for each: every compute daemon
  compiled each stage for each edge shape it met, about 2.5 s a shape for
  the robust Kalman smoother and half the compute time of hutan's SI tail
  at 5.76 M cells. An edge chunk's inputs now grow to the modal shape with
  nodata, as beyond the raster's edge, run the kernel compiled for that
  shape and have the padding cropped from the outputs
  (`garry.pad_edge_chunks`). This holds for compute stages on daemons, in
  a single process, and fused onto reads; spatial reductions and model
  (patch) stages keep their own shapes. The tail's drain went from 40 s to
  30 s with two compute daemons and from 31 s to 23 s with six, with
  identical products; a single-process robust smoother over four chunk
  shapes went from 3.7 s to 2.6 s.
* Reads with a fused kernel no longer run a full garbage collection after
  every window; the daemon's deferred pass collects them.
* Compute daemons clean up after a task with a minor garbage collection,
  and a full one once 512 MB of task data has passed since the last. A
  full collection walks every
  kernel the daemon has compiled and took a fifth of the SI tail's
  compute time.
* Write quantization on a daemon runs as one jitted kernel rather than
  seven passes over the output.

* A full read store no longer serialises the compute pool. When the
  resident read regions exceeded their budget, only one compute task could
  run at a time, and compute tasks are what free those regions, so the
  store stayed full. Now one compute task per compute daemon may run. On
  hutan's SI tail at 5.76 M cells with two compute daemons, the second
  daemon went from 36 of 650 compute tasks to 335, and the drain from
  56.9 s to 43.5 s, for about 0.3 GB more shared memory at peak.

* The bands of one file collapse into a single read per window when the
  file's bands share storage (a Zarr array, a pixel-interleaved file),
  also through a warp onto a target grid and through `lazy_map()` applied
  per band. A pooled read of a 128-band OlmoEarth window fetched 11 times
  its bytes before (102 s for 1024 x 1024 pixels) and fetches them once
  now (14 s). Band-interleaved files keep their per-band reads.
* A Zarr dataset handle is closed once it has read 256 MB, and daemons
  close their Zarr handles between runs, since GDAL
  keeps every chunk it decodes for the life of the handle.
* A Zarr store on a reprojected grid warps window by window from its
  cached handle rather than through a warped VRT, which reopened the store
  inside GDAL for every read.

## Bug fixes

* A fused integer kernel comes back as integers: under the pools its
  export was read as floats, and an `Int16` chain aborted.
* An integer stage's ring beyond the raster is 0 at every width: `i64`
  and `u32` values took NaN and failed the next stage.
* A kernel that reads an array inside a classed list or an environment
  no longer shares a program with another that holds different values,
  and a kernel that calls itself has an identity. Editing a global a
  kernel only shadows no longer recompiles it.
* A stage with very many inputs no longer aborts on R's symbol limit.
* A failed task reports its daemon's whole error, GDAL's cause and the
  next step included, under the daemon's own class. A signed URL's query
  string stays out of GDAL's text. A daemon lost under a broadcast
  reports what the broadcast was for, under its class.
* A read-only write whose writer dies between writes fails, where it
  hung. An auth error holding `{` keeps its text, and its previous header.
* A tile off the grid fetches its corner pixel, where the run aborted.
* A failed Zarr warp reports GDAL's cause.
* `stac_filter_assets()` on a table and `stac_sources()` warn of a
  missing asset. A token or weights cache that cannot be written warns,
  and the run goes on.
* `preview()` says when it must read at full resolution.
* `g_ifelse()` takes a stored 0/1 mask: nonzero is true, as in `ifelse()`.

* A streamed write of a plan that only reads holds its read budget as the
  scheduler does: priced from launch, and inside what RAM, `/dev/shm` and
  the cgroup allow now, re-read every 5 s. The writer also releases its
  shared-memory mappings as it goes, so a region the readers have dropped
  frees at once.
* A write GDAL could not finish fails the run with a `garry_write_error`
  naming the file. gdalraster's `close()` raises nothing, and threaded
  GTiff compression returns success for a tile the disk refused, so a
  full disk could end in a returned path and an incomplete file. A
  window write now listens to GDAL's error handler, an output flushes
  before it closes, and a closed GTiff's directory is checked against
  its size, which catches the last bytes GDAL loses with every status
  clean. A writer daemon that dies under the close fails the write, and
  `write_tif(cog = TRUE)` reports why a finalise failed.
* A pool that lost its daemons fails the next run with a
  `garry_pool_error`. `garry_daemons_set()` now says the pools were set,
  as `mirai::daemons_set()` does, not that a daemon is alive: it read
  `FALSE` once every compute or read daemon had died, and the job moved
  onto the host with no message. A dead writer fails a write the same
  way, where it used to run on the host's dispatch thread, and only a
  run that writes needs it.
* A setup broadcast that fails on a daemon aborts, naming the cause.
  Failures of `garry_daemons()`, of a run's start and of the pid query
  came back as values nobody read, leaving stale policy, no CPU masks or
  no memory measurement. The read policy now reaches every daemon the
  same way on every route.
* `garry_daemons(gdal_config = FALSE)` holds on every route: the
  gdal-direct routes applied the GDAL config anyway. It no longer drops
  the `MALLOC_*` defaults, and `gdal_cachemax_mb` reaches every daemon.
* A cgroup limit file that cannot be read or parsed fails with a
  `garry_memory_error`. It meant "unlimited", so the budget ignored the
  limit. Unknown RAM, which opens every memory budget, warns once.
* A CPU mask that cannot be set warns on Linux, naming why, where the
  pool used to run uncapped with no message.
* A source that fails to open while a plan is made fails the plan with a
  `garry_read_error` naming it, after `garry.read_retry` retries. A
  transient failure used to choose a slower read: the warper for a
  session on a multi-source read, or per-band reads of a Zarr store.
* A failed kernel warm-up warns and leaves a `warm_fail` task-log row, and
  the kernel compiles in its first task. A warm-up failed silently before.
* A Planetary Computer token that cannot be refreshed warns while the
  signed URL lasts and aborts once it has expired, where the old URL went
  on to a 403 that said nothing of the refresh.
* A header push a daemon refuses fails the run, and the next run pushes
  again: the refused value used to count as delivered.
* `scale = TRUE` on a band with no scale metadata warns, classed
  `garry_scale_warning`, where it informed. The band reads raw, since GDAL
  cannot tell a declared identity from no scale at all.
* Dataset arithmetic needs the same value bands on both sides. `a + b`
  dropped the bands only one side held. Select them first: `a[bands] +
  b[bands]`.
* `kalman_llt()` and `kalman_smooth()` keep NaN in the sd where the
  variance is NaN. A broken covariance reported an sd of 0, perfect
  certainty, beside a NaN mean. Other values are unchanged.
* No wait on a daemon outlives it: broadcasts, the ABI check and the
  writer's closes and cleanup check liveness, so a daemon killed under
  any of them fails the run in seconds where it used to hang the host.
* `lazy_dataset()` refuses a per-band argument it cannot place, with a
  `garry_source_error`. In `nodata`, `scale`, `offset` and `resampling`,
  a key that names no band or asset of the source aborts, where a typo
  used to leave the band on its file metadata with its sentinels in the
  data. So do several unnamed values, which read as the first, a blank,
  repeated or `NA` name, and an empty value.
* A non-finite `scale` or `offset` in `lazy_dataset()` or `lazy_source()`
  aborts with a `garry_source_error`.
* The file form of `lazy_dataset()` keys a named `scale` and `offset` by
  band: `scale = c(nir = 0.5)` used to halve every band. In both forms an
  offset keyed to a band with no scale applies at scale 1, where it was
  dropped.
* `stac_drop_duplicates()` dates a range-only item by its
  `start_datetime`, as `stac_sources()` does. On a `doc_items`, items with
  a null `datetime` on one footprint collapsed to the first, so an annual
  product kept one year.
* `write_tif()` and `materialise()` check `nodata` against the dtype they
  write, the plan's own when `dtype` is not given, and abort with a
  `garry_write_error`. `nodata = -1` on a u8 plan stored holes as valid 0
  under a band declaring -1. `NA` and a value beyond f32 range abort too.
* `write_tif()` refuses, with a `garry_write_error`, a creation option
  that is not `KEY=VALUE` or `KEY:VALUE` and a block size that is not a
  positive whole number. GDAL read `BLOCKSIZE=abc` as 0, and the
  COG driver then allocated without bound (54 GB in 45 s).
* A `write_tif()` refused before it starts leaves an existing file at
  `path` in place. A bad `nodata` or `distributed = TRUE` with no pools
  used to delete it.
* A raster's dtype is now what its kernel returns. `lazy_map()`,
  `scan_over()` and a custom `reduce_over()` trace `fn` on abstract inputs
  when the raster is built, unless `dtype` names it, and a kernel's output
  leaves its stage at the declared dtype. `lazy_map(int_raster, fn =
  function(v) v / 2)` is f32 on every route: it used to give 1.5, 1 or 2
  depending on the route, and write Int16. A `fn` that cannot trace fails
  where the raster is built, with a `garry_kernel_error`.
* Integer sums no longer wrap. `reduce_over(x, "sum" or "mean", c("x",
  "y"))` over an integer raster accumulates in f64 (a 1000 x 1000 Int16
  raster of 3000 averaged -1295), a spatial integer sum declares i64, and
  32-bit integers sum in i64 along a stack.
* `write_tif(scale = )` quantizes an integer plan as it does a float one.
  The in-process route stored its values unscaled under valid metadata.
* A kernel output of a 64-bit integer dtype, and so any computed u32
  raster, reaches R as doubles. Across chunks it used to arrive as
  denormal garbage.
* An integer source reads at the float that holds it when it needs NaN
  (nodata, a scale, a focal window or a patch): f32 up to 16 bits, f64
  above, where Int32 and wider used to round to f32 above 2^24. Window
  warps and the warp-on-read routes keep Float64, Int32 and wider sources
  exact too, and `stage_raw_cube()` writes such sources to a Float64 cube.
* A missing cell in an integer raster fails. `g_upload()` turned NaN into
  0, so a cell no tile reaches read as a valid 0. It now raises a
  `garry_nodata_error`: declare `nodata` on the source.
* Focal windows see NaN past the raster edge over anything built on an
  integer source: a map, a warp, a stack, a reduction. The edge read 0
  there.
* `lazy_dataset()` takes each band's dtype from that band, not band 1.
* A fractional or NaN scalar meeting an integer array in `g_ifelse()` or
  `g_pad()` fails with a `garry_kernel_error`. It used to truncate.
* `apply_mask()` and `shrink_footprint(boundary = "keep")` work on integer
  bands, which they promote to a float, and `apply_mask()` keeps an f64
  band at f64 on every route.
* Computing on a spatial reduction, `reduce_over(x, "mean", c("x", "y")) +
  1`, fails at plan time with a `garry_reduce_unsupported_error`. It failed
  mid-run with an error from pjrt.
* A multi-band warp of several sources or a Zarr array masks each band's
  nodata alone. GDAL's default (`UNIFIED_SRC_NODATA=PARTIAL`) masked a
  pixel only when every band held nodata, so one band's sentinel came
  through as a value and, from a later source of a mosaic, overwrote an
  earlier source's data.
* `garry.warp_exact = TRUE` warps windows with GDAL's exact transformer,
  as the warped VRT of a single source already is, so which source pixel
  a cell takes never depends on where windows fall. GDAL's default
  interpolates the transform along each row of a window to within 0.125
  px. It is off by default: a one-band warp across projections costs
  3-15x more with it.
* A direct (unwarped) read declines a source whose band has a mask or
  alpha band, which the warper honours and a plain read did not.

* Read daemons can open Zarr stores: the vsicurl allowlist admits Zarr v3
  and v2 metadata and chunk keys.
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
* Memory budgets respect a container's limit. Inside a container with its
  own cgroup namespace (Docker's default on cgroup v2) and on cgroup v1,
  garry found no limit and budgeted against the host's RAM.
* `garry_daemons()` caps the GDAL block cache of every daemon at
  `garry_opt("gdal_cachemax_mb")`, not only the read daemons'. The compute
  daemons and the writer were on GDAL's default of 5% of RAM each, about
  12 GB apiece on a 240 GB machine.

* What identifies a source now survives every read. `align_to()` of a
  source opened with options (a GTI slice) read the unfiltered index,
  so the wrong time slice arrived without an error; the warped VRT and
  window warps now carry the options. `extract_points()` refuses such a
  source and asks for `materialise()`. `lazy_source()` refuses
  `open_options` with several paths or `decode`, with a
  `garry_source_error`.
* `lazy_source(nodata = )` and the file form of `lazy_dataset()` now
  replace the file's sentinel on every read. A plain read masked both,
  so the same cell was NaN by direct read and data through the warper.
  A tile index or a source opened with options cannot replace its own
  sentinel: reads mask both, as before, and `align_to()` refuses at plan
  time instead of taking its gaps as data.
* `lazy_dataset(paths)` no longer mosaics tiles off one pixel lattice,
  which averaged their resolution or moved pixels: they need `grid` and
  then warp onto it. Tiles kept apart must agree on dtype, on any nodata
  they declare and, with `scale = TRUE`, on their affine, each otherwise
  a `garry_source_error`; a sentinel of a later tile used to enter as
  data. Tiles with gaps and no sentinel stay apart, so a gap is missing,
  not 0.
* A warp of an integer source with no nodata marks cells past its
  footprint as missing instead of 0: `collect()` shows NaN, and a compute
  stage or integer write fails and asks for `nodata`. A warp of an
  integer band under a window, or with a sentinel the band cannot hold,
  had GDAL clamp the destination nodata: the first turned source 0s into
  1s, the second could abort the process.
* Numbers cross to GDAL through one 17-digit formatter. A fractional
  `-srcnodata` kept 7 digits and stopped matching, and a composite's
  target grid kept 10, up to about 5 mm off at 1e7 coordinates.
* Per-band GTI `resampling` shared one wrapper file, so the last method
  applied to every non-nearest band of an asset; a warp of a GTI source
  also dropped the source's own resampling. Several sources on their
  planning grid now read by `resampling`, which `grid = NULL` ignored,
  and `coarsen()` refuses a source read by anything but nearest neighbour.

## Observability

* Warnings carry the parent class `garry_warning` and a class of their
  own (`garry_memory_warning`, `garry_affinity_warning`,
  `garry_warmup_warning`, `garry_read_warning`, `garry_scale_warning`), so
  a caller can handle them by class.
* The task log gains `retry` rows (a task's read retries, which a daemon
  cannot otherwise report), `resend` rows (a kernel sent again to a daemon
  that lacked it) and `warm_fail` rows.

* The task log (`garry.task_log`) tags each daemon's memory sample with its
  role (read, comp or write), and samples the calling process's memory,
  the container (cgroup) usage against its limit, `/dev/shm` use and the
  compute and read admission budgets. `garry_task_report()` summarises
  them. Sampling and the memory guard now run every 5 s during a drain,
  including while every daemon is busy with a long task.
* The task log records when a daemon starts each task (`start` rows), and
  `garry_task_report()` splits the time a task queued behind its daemon's
  previous task from its run time. Launch-to-done alone held both, so a
  busy daemon's tasks read about twice as slow as they ran.
* The task log also records when a daemon finishes each task (`end`
  rows), and `garry_task_report()` splits the harvest lag (the result's
  return and the host noticing it) from the run time.
* A plan that only reads now logs its tasks too, written (`write_tif()`
  of a dataset, say) or collected with daemons: each read on the read
  pool and each write on the writer daemon, with start and end times,
  and memory samples every 5 s. Before, such runs left no rows in the
  log. Every run also logs its pool widths, and `garry_task_report()`
  adds each pool's busy seconds and the last run's share of each pool's
  time busy, which shows whether the readers or the writer set the
  pace.
* The task log now covers the composite and reduce routes (fetches, the
  mask, band strips and warm-ups, with memory samples) and the
  scheduler's writes and kernel warm-ups, each with start and end times.
  Without `garry.task_log` none of this costs anything.

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
