# Handoff: `ck_batch_to_buffer()` in cptkirk

Status: **spec, not started.** Self-contained brief to implement in
`~/belian/cptkirk`, then wire the garry side (section 5). Written 2026-07-16.

## 1. Why

garry's `lazy_cog` collect-time resolver (`R/lazy_cog.R:.ck_resolve`) has two
fetch paths:

| Case | cptkirk call | Intermediate |
|---|---|---|
| Multi-band single COG, and lone single-band sets (AEF) | `ck_warp_to_buffer` | raw BSQ buffer, **no encode** |
| >1 single-band sets sharing (grid, bands, resampling) — the HLS time series | `ck_batch(stack = FALSE)` | **one GTiff per tile**, then local `gdal_mosaic_vrt` |

The multi-slice single-band path pays a full GeoTIFF round-trip per tile:
cptkirk **encodes** each warped tile to GTiff, garry **decodes** it back through
the mosaic VRT. The staging is on `/dev/shm` (tmpfs), so this is encode/decode
**CPU**, not disk I/O, but it is work the buffer path does not do.

The measured shape that motivates removing it: cptkirk fetch (~17.7s) ≈ GDAL
fetch (~16s) on the HLS median benchmark, yet total cptkirk collect was ~30s vs
lazy_dataset's ~16s. That leaves **~13s of post-fetch overhead**, and the GTiff
encode+decode sits inside it. We never isolated encode from local-mosaic from
scheduling. `ck_batch_to_buffer` removes the encode+decode term cleanly and lets
us re-benchmark to see how much of the gap it was.

Secondary win: it unifies both paths on the raw-f32 no-encode model and drops
the GTiff-of-tiles + `gdal_mosaic_vrt` step from the batch path.

## 2. What to build

`ck_batch_to_buffer()`: `ck_batch()` with the per-output destination changed
from a GeoTIFF file to an in-memory raw buffer, exactly as `ck_warp_to_buffer()`
is `ck_warp()` with that same change. Reuse both existing functions' internals;
this is a destination swap, not a new pipeline.

### Signature

Mirror `ck_batch()`'s AOI/fetch args, drop the file args (`dst`, `tap` file
template), add `ck_warp_to_buffer()`'s buffer args (`dtype`, `fill`,
`max_bytes`):

```r
ck_batch_to_buffer(src, stack = FALSE,
                   t_srs = NULL, te = NULL, te_srs = NULL, tr = NULL, ts = NULL,
                   r = <same enum as ck_batch>, bands = NULL, dtype = NULL,
                   fill = NULL, cl_arg = character(0),
                   num_threads = 1L, warp_memory = "auto", cache_max = "auto",
                   config = NULL, overview = NULL, margin = 8L,
                   io_concurrency = 16L, prefetch = NULL, max_bytes = NULL,
                   sanitise = TRUE)
```

`src` is the same nested list as `ck_batch` (one element per group, each a
character vector of band/tile URLs). `num_threads` keeps `ck_batch`'s `1L`
default (many small warps).

### Return

Structure-preserving, mirroring `ck_batch`, but each leaf is a **buffer
descriptor** instead of a path — the identical list `ck_warp_to_buffer()`
returns:

```
{ data (raw, BSQ), nx, ny, nbands, dtype, nodata, geotransform, crs }
```

* `stack = FALSE` (what garry needs): a list (one per group) of lists (one per
  band/tile) of descriptors. `NA` where a source did not overlap the AOI or its
  fetch failed (warn), matching `ck_batch`.
* `stack = TRUE` (optional, for API symmetry; garry does not use it): one
  descriptor per group, its bands stacked BSQ (`nbands > 1`).

Each descriptor's geometry must match what `ck_batch` would have written for that
output — same per-output window and geotransform (garry mosaics by georeference,
so per-tile clipped buffers are correct and cheaper than full-AOI ones). Do **not**
force every tile onto the full `te`/`ts` grid.

### Where the swap goes

`ck_batch` streams windows and, per output, calls
`.stack_assemble(ws_u, pl_u, dst1, ...)` (warp + write to the file `dst1`),
overlapping warp with in-flight fetches and optionally dispatching across the
ambient mirai pool (`.batch_stream_run`, `R/ck_batch.R`). The buffer variant
keeps all of that and only replaces the assemble step:

* Add `.stack_assemble_to_buffer(ws_u, pl_u, geom, ...)` that warps into a MEM
  `DATAPOINTER` dataset over a pre-filled raw R buffer and returns the descriptor
  — lift the buffer tail of `ck_warp_to_buffer()` verbatim (allocate + `fill`
  pre-fill or `INIT_DEST`, `.get_data_ptr`, `MEM:::DATAPOINTER=...` DSN with the
  BSQ PIXEL/LINE/BAND offsets, `gdalraster::warp`, read back). The output
  geometry (`nx/ny/gt/nbands/dtype`) comes from the per-output plan `pl_u`, the
  same source `.stack_assemble` uses to size its file.
* In `.batch_stream_run`, dispatch `.stack_assemble_to_buffer` in place of
  `.stack_assemble` and collect descriptors into the same nested structure the
  path version builds.

### Daemon note

When the ambient mirai pool is active, the per-output warp runs in a daemon.
Input window bytes are already handed over zero-copy via `mori::share`. The
**output** buffer is filled in the daemon and returned to the parent through the
normal mirai return (one serialized copy of the raw vector). That is fine and
needs no `mori` on the return; just ensure the daemon branch returns the
descriptor list, not a path.

### Memory ceiling

`ck_warp_to_buffer` bounds a single buffer with `max_bytes` (~1/3 RAM default).
For a batch, **all** descriptors are resident at once (raw and uncompressed),
which can exceed the current `/dev/shm` GTiff footprint if those GTiffs are
compressed. Apply `max_bytes` as a ceiling on the **running sum** of allocated
buffers across the batch and abort with the same coarsen/narrow/raise guidance
if it would be exceeded.

## 3. Non-goals

* No change to `ck_warp_to_buffer` or `ck_batch`; this is a third entry point.
* garry does not need `stack = TRUE`; build it only if cheap given the shared
  assembler.
* No VRT output from cptkirk (async-tiff rejects VRT magic bytes; garry builds
  the mosaic VRT locally, as today).

## 4. Acceptance (cptkirk side)

* `ck_batch_to_buffer(src, stack = FALSE, te=, ts=, ...)` on a 2-group,
  multi-tile-per-group input returns a list-of-lists of descriptors whose
  `data`/`geotransform`/`crs` reproduce, tile for tile, what
  `ck_batch(stack = FALSE)` writes then `gdalraster::read_ds` reads back (byte
  and georeference identical).
* Non-overlapping source → `NA` leaf, with the warning, as `ck_batch`.
* Runs with and without an ambient mirai pool, same result.

## 5. garry-side wiring (do once cptkirk lands)

Rewrite `.ck_batch_mosaic` (`R/lazy_cog.R:240`) to consume buffers instead of
files:

1. Call `cptkirk::ck_batch_to_buffer(src = src, stack = FALSE, t_srs = s0$crs,
   te = s0$te, ts = s0$ts, bands = ..., r = s0$resampling, io_concurrency = 32L)`.
2. For each returned tile descriptor, stage a raw `.bin` + VRTRawRasterBand VRT.
   Factor the staging out of `.ck_fetch` (`R/lazy_cog.R:264`) into a shared
   `.stage_buffer(res, root)` helper (writeBin + `.raw_bsq_vrt_xml`, relativeToVRT
   sibling); `.ck_fetch` calls it too, so the two paths share one bridge.
3. Mosaic each set's per-tile raw VRTs with `gdal_mosaic_vrt` — nested VRT (the
   mosaic VRT references the child VRTRawRasterBand VRTs). Confirm GDAL buildVRT
   accepts VRT children (it does); if a child path issue arises, point the mosaic
   at the `.bin` via absolute source and keep relativeToVRT on the child.
4. Record the staged mosaic path exactly as now. The `.ck_fetch` lone-set and
   multi-band paths are unchanged.

No test rewrite expected: `test-lazy-cog.R` and `test-stac-doc-items.R`
(`lazy_cog accepts a doc_items`) already exercise multi-tile single-band sets;
they must stay byte-identical. Add one asserting no `cb_*.tif` is produced.

## 6. Validate + benchmark

* Suite green, `lazy_cog` outputs byte-identical to the current GTiff path
  (same collect result on the doc_items and lazy-cog fixtures).
* Re-run the HLS median cptkirk-branch benchmark. Compare against the ~30s
  baseline and lazy_dataset's ~16s. Report how much of the ~13s post-fetch
  overhead the encode/decode removal recovers. Outcome either way is a result:
  * closes most of it → cptkirk becomes competitive on time series, routing split
    relaxes;
  * does not → overhead is local-mosaic/scheduling, and "lazy_dataset for single-
    band time series" stands on isolated evidence.

## 7. Risks / open

* **Memory**: uncompressed buffers resident for the whole batch. The summed
  `max_bytes` guard is the backstop; for very large many-slice AOIs the GTiff
  path may still be preferable, so keep `.ck_batch_mosaic` able to fall back (or
  cap batch size) rather than deleting the GTiff path outright until the
  benchmark says it is unneeded.
* **Nested VRT**: verify `gdal_mosaic_vrt` over VRTRawRasterBand children reads
  correctly under both executors (single-threaded and mirai daemons) — the raw
  `.bin` siblings must resolve from the daemon's working directory (they live
  under the shared `/dev/shm` root, so they do).
* **`.get_data_ptr`**: cptkirk already uses `gdalraster:::.get_data_ptr`; garry
  now resolves it via `getFromNamespace` to keep R CMD check clean (see
  `R/gdal_adapter.R:.gdalraster_data_ptr`). No change needed in cptkirk.
</content>
</invoke>
