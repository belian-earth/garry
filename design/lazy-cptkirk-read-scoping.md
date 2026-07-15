# Step B scoping: lazy-at-collect cptkirk multi-band read

Scope for moving the cptkirk multi-band COG read from eager (at the `read_cog`
call) to lazy (at `collect()`): auto-selected, coalesced to one
`ck_warp_to_buffer` per source set, and folded so a user builds a dataset and
collects with no special reader call. Companion to `aef-multiband-read.md`
(step A, the native buffer read, is built and on this branch).

## Goal

A multi-band COG (or a mosaic of them) becomes a `LazyDataset` whose per-band
reads are deferred to `collect()` and, at collect, fetched+warped in one cptkirk
pass per source set rather than one GDAL open per band. Compute (dequant, band
algebra, PCA) stays lazy and fuses on top. cptkirk becomes an `Imports`.

## Read-path facts that constrain the design (from recon)

1. Band algebra over `lazy_source()` layers routes to the GENERAL executor
   (`execute_plan_mirai` / `execute_plan`): both `.cd_spec` and `.gd_decompose`
   return `NULL` (no GTI sidecar; no leaf temporal reduce). `R/collect.R:48-67`.
2. The general source read is `.exec_read_padded` -> `gdal_read_window`
   (`R/executor.R:23`, `R/gdal_adapter.R:128`): a plain windowed RasterIO, NO
   warp. It assumes the source is already grid-aligned.
3. Reprojection is a SEPARATE `WarpNode` / "warp" stage via `gdal_warp_vrt`
   (`R/executor.R:401`, `R/gdal_adapter.R:169`), introduced only by explicit
   `align()`. The source read never warps.
4. There is ONE GDAL open per `SourceNode`; no coalescing of distinct sources.
5. `prepare_fetch(rpath, roo, rnodata, grid)` (`R/scheduler.R`, called at
   `R/scheduler.R:679`) is a collect-time fetch/prepare phase that fires ONLY for
   GTI sources (marker: `startsWith(rpath, "GTI:")`). It returns `NULL`, or
   `list(deps = <fetch task ids>, local = <local path to read>, files = ...)`;
   the source read then reads `fp$local` after `deps` complete, routed to the
   compute pool. This is the template step B needs.
6. Upload is `g_upload_raw(raw, "f32", c(ny, nx))`, row-major (`R/scheduler.R:76`,
   `R/executor.R:142`).
7. `lazy_dataset` (`R/dataset.R`) is the STAC+GTI TIME-SERIES model: one band per
   asset per time-slice, each a `lazy_source` over a per-asset GTI mosaic with a
   `slice = '...'` FILTER. Multi-band assets are NOT expanded to N bands.

## Design: cptkirk as a `prepare_fetch` sibling

`prepare_fetch` already models exactly the shape we need: a collect-time phase
that stages remote data locally, decoupled from the chunked read, with the read
consuming the staged local path after the fetch completes. Step B adds
`prepare_cptkirk`, a sibling, and reuses step A's staging (`.ck_warp_buffer`,
`.raw_bsq_vrt`) verbatim, only moving the call from eager to a collect-time task.

- **Marker (no IR change):** a source path prefix `"CK:<srcset>"`, mirroring
  `"GTI:<idx>"`. The tile set (one or many) and read parameters ride in the path
  / `open_options`; the band is the existing `node@band`; the target grid is the
  existing `node@grid`. No new `SourceNode` field, so every other executor path
  treats it inertly (its `prepare_*` simply returns `NULL`).
- **`prepare_cptkirk(rpath, roo, rnodata, grid)`:** returns `NULL` unless
  `startsWith(rpath, "CK:")`. Otherwise, keyed on `(srcset, grid, resampling)` in
  a per-plan cache, the FIRST band to arrive registers ONE fetch task running
  `ck_warp_to_buffer(srcset, grid, bands = <union needed>)` -> `.bin` + VRT (step
  A), and returns `list(deps = fetch_task, local = <VRT>, files = ...)`.
  Subsequent bands of the same source set reuse the cached task and VRT (the
  coalescing). All N band reads depend on the one fetch.
- **The source read is UNCHANGED:** `gdal_read_window` over the staged VRT at
  `band = node@band`. Native dtype -> D8 sentinel->NaN -> dequant map fuses in the
  compute stage, exactly as step A.

So step B is almost entirely a scheduler addition; the read, upload, dequant and
nodata handling carry over from step A untouched.

## What changes (files / functions)

1. `R/scheduler.R`: `prepare_cptkirk` + a per-plan `srcset -> {task_id, vrt}`
   cache; wire it into the `source_read` branch beside `prepare_fetch`
   (`R/scheduler.R:679`), sharing the fetch-deps / compute-pool routing and the
   `fetch_reads_left` accounting.
2. The fetch task body: `.ck_warp_buffer` (step A) as a mirai task on the read
   pool.
3. Construction/API (the decision below) emits `"CK:"`-prefixed sources.
4. `R/executor.R`: mirror any single-threaded `prepare_fetch` path so
   `execute_plan` (non-distributed) also works, or document distributed-only.
5. `DESCRIPTION`: cptkirk `Suggests`/soft -> `Imports`; drop the
   `getExportedValue` shim for a `cptkirk::` literal; add the Rust build to CI.
6. `read_cog`: becomes a thin builder of the lazy dataset (no eager fetch), or is
   removed in favour of the construction API below.

## The construction / API question (needs a decision)

`lazy_dataset` is the STAC+GTI time-series model and does not fit a single
multi-band COG stack cleanly. Options:

- **(a) Teach `lazy_dataset` to expand a multi-band-COG asset** into N
  cptkirk-flagged bands. Matches "select the reader in `lazy_dataset`" literally,
  but bolts a non-time-series shape onto the STAC/GTI machinery.
- **(b) A dedicated lazy multi-band reader** (`lazy_cog`, or keep the `read_cog`
  name but make it lazy) that emits `"CK:"`-flagged sources. Cleanest
  separation; "auto-select" is simply: multi-band COG -> cptkirk engine,
  single-band -> plain `lazy_source`.
- **(c) Both:** (b) now for the direct case; (a) later if multi-band STAC assets
  become common.

Recommendation: **(b) first.** It delivers the AEF workflow lazily with the least
coupling and reuses step A directly; fold detection into `lazy_dataset` (a) later
if multi-band STAC assets appear. (Confirm.)

## Coalescing scope

Key on `(source-set, target grid, resampling)`. Bands fetched = union of the
dataset's bands drawn from that source set. `ck_warp_to_buffer` accepts multiple
`src`, so a mosaic of tiles is one call that warps+mosaics all tiles' bands. The
coalescing key is therefore the source SET, not a single file.

## Carried over from step A (no redesign)

- Dequant is a `lazy_map` per band, fusing in the compute stage.
- Nodata read dynamically from the source; native-dtype read triggers the D8
  sentinel->NaN promotion; the decode never sees the sentinel.
- The staged VRT is native (e.g. Int8); the read promotes to f32 (D8). Uploading
  native i8 to anvl instead of f32 is a later micro-opt; the f32 VRT path reuses
  the existing `g_upload_raw` "f32" contract.

## Risks

- `prepare_fetch`'s per-plan state and task-dependency wiring (deps, pool
  routing, `fetch_reads_left`) are intricate; `prepare_cptkirk` must mirror them
  exactly, and be inert for every non-`CK:` source.
- `execute_plan` (single-threaded) has its own read path; parity needs a look.
- cptkirk `Imports` adds a Rust build to garry CI on Linux/mac/win, the reason it
  was kept soft so far. Sequence B3 after B1/B2 prove out.
- Live testing needs network + an AEF tile (deferred to a fast link).

## Resolved decisions (2026-07-15, Hugh)

1. API shape: **dedicated `lazy_cog`** (option b). A lazy multi-band reader
   emitting `"CK:"`-flagged sources; multi-band COG -> cptkirk, single-band ->
   plain `lazy_source`. `lazy_dataset` multi-band-asset expansion is deferred.
2. Engine marker: the **`"CK:"` path prefix** (no `SourceNode` field change).
3. cptkirk -> **`Imports` now, with B1**: call `cptkirk::` directly (drop the
   `getExportedValue` shim) and add the Rust build to CI from the start, so CI
   exercises the real dependency. The phased plan below folds the former B3
   Imports step into B1.

## Phased plan (revised for the decisions)

- **B1 (BUILT)**: `lazy_cog()` emitting `"CK:"` sources (fetches nothing at
  construction); a collect-time pre-pass `.ck_resolve` in `collect()` that
  fetches each source set once (one `ck_warp_to_buffer`), stages the native BSQ
  buffer as a `.bin` + VRTRawRasterBand VRT, and rewrites the source paths so
  BOTH executors read the VRT unchanged. cptkirk is `Suggests` guarded by
  `rlang::check_installed` (pak builds the Rust; nothing special in CI, so no
  workflow change). `read_cog` removed. 17/17 lazy-cog tests pass end-to-end on a
  local tiled COG.
- **B2 (BUILT)**: mosaic via `lazy_cog(path = c(...))` -> one `ck_warp_to_buffer`
  that stitches the tiles. Tested on two adjacent local tiled COGs.
- **B3 (BUILT)**: stage on tmpfs `/dev/shm` when available (RAM-backed, no disk
  round-trip) rather than `/vsimem`. NOTE: `/vsimem` is per-process and invisible
  to the mirai daemons; `/dev/shm` is a real shared path they can read, matching
  `prepare_fetch`. Validated by a distributed-daemon read test. Optional native-i8
  upload (vs the f32 read of the VRT) remains a later micro-opt.

### Why the pre-pass, not `prepare_cptkirk` in the scheduler

The scoped `prepare_cptkirk` (a `prepare_fetch` sibling that overlaps fetch with
compute) would need mirroring into BOTH `execute_plan_mirai` and the
single-threaded `execute_plan` (used as the test baseline), a large intricate
surface for little gain on the COG case: a single multi-band stack is one fetch
then compute, not many overlapped time-slices. The pre-pass gives lazy-at-collect
and per-source-set coalescing with no executor changes and clean offline testing.
Fetch/compute overlap in the scheduler stays a later optimization if `lazy_cog`
over many tiles/slices shows it matters.
