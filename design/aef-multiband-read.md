# Fast multi-band COG reads for geo-embeddings (AEF) — investigation + plan

Status: **first slice BUILT (`read_cog`), benchmark + optimisation pending.**
Paused 2026-07-15. This note is self-contained to resume from.

**Built (R/read_cog.R, tests/testthat/test-read-cog.R, suite green):**
- `read_cog(path, grid, bands=, dequant=, resampling=, names=)` — eager cptkirk
  fetch+warp of a multi-band COG onto `grid` → a `LazyDataset` (one band per
  source band), downstream compute stays lazy.
- `dequantize_aef(x)` = `((x/127.5)^2)*sign(x)` in the `g_*` vocab — the fused
  decode map; pass as `read_cog(dequant = dequantize_aef)`.
- `.cog_to_dataset()` — garry-side wrapping (tested offline, no network/cptkirk).
- `.ck_warp_local()` — the cptkirk call, a **soft dependency** resolved at run
  time via `getExportedValue("cptkirk","ck_warp")` (no `cptkirk::` literal), so
  garry's DESCRIPTION/CI stay clean (no Rust build pulled in). It currently uses
  cptkirk's existing `ck_warp` → a local GTiff; **swap to cptkirk's raw
  warp-to-bin when available** to drop the GeoTIFF round-trip.

**BUILT (2026-07-15, step A — native buffer read via `ck_warp_to_buffer`):**
`read_cog` now fetches through cptkirk's `ck_warp_to_buffer` (native BSQ buffer,
no GeoTIFF), stages it as a raw `.bin` + a `VRTRawRasterBand` VRT
(`relativeToVRT` sibling, so GDAL's raw-band security gate is satisfied without
loosening `GDAL_VRT_RAWRASTERBAND_ALLOWED_SOURCE`), and reads it via
`lazy_source` at the source's NATIVE dtype so the D8 sentinel->NaN promotion
fires. The nodata sentinel is read from the source dynamically (`.src_nodata`),
never assumed. Fixed a real latent bug: `dequantize_aef` overflowed in Int8
(`x*|x|` before promotion) -> now `xn*|xn|`, `xn = x/127.5` (divide first). These
anvl tests were skipped in the prior "green" run, hiding it. `.raw_bsq_vrt`,
`.gdal_dtype_bytes`, `.src_nodata` added; 12/12 read-cog tests pass.

The fetch is still EAGER (at the `read_cog` call). The VRT/.bin bridge exists
only so the eager read reuses `lazy_source` while keeping compute lazy; the
lazy-at-collect design (below) deletes it (executor `g_upload_raw`s the planes at
collect). Interim win available: stage `.bin`+`.vrt` in `/vsimem` not disk.

**CONFIRMED DIRECTION (2026-07-15): lazy-at-collect, auto-selected in
`lazy_dataset`, cptkirk as Imports.** The native buffer read (above) is step A;
the target is:
1. **cptkirk `ck_warp_to_buffer()`** (prerequisite, Hugh implementing) — warp the
   fetched/staged VRTs into a raw NATIVE-dtype BSQ buffer via `MEM:::DATAPOINTER`
   (the `gdal_warp_to_buffer` contract generalized to `BANDS=N`, native). Full
   spec: **`~/belian/cptkirk/HANDOFF-ck_warp_to_buffer.md`**.
2. **garry `lazy_dataset()`** auto-detects tiled multi-band COG assets
   (`gdal_band_count > 1`) → expands each to N band-sources flagged
   `engine = "cptkirk"`; single-band assets untouched.
3. **garry read dispatch (lazy, at collect)**: for cptkirk-flagged sources,
   coalesce the N same-file band-sources into ONE `ck_warp_to_buffer` call, slice
   the BSQ planes → per-band `.bin`s → anvl upload (native dtype) → fused
   `dequantize_aef`. Replaces the per-band warp-on-read for multi-band.
4. **Remove `read_cog`** (fold into the engine); keep `dequantize_aef`. cptkirk
   -> **Imports** (+ a Rust build step in garry CI). Rationale (Hugh): folded in,
   it must always be available, and multi-band remote COGs are common beyond
   embeddings.

**Also still to do:** run the read benchmark on a fast link (decisive: cptkirk
vs one GDAL multi-band warp); decide the Rust-direct question by measurement. The
benchmark was inconclusive (test link slowed mid-run).

## Goal

Read multi-band geo-embedding COGs (Alpha Earth Foundations, "AEF") into garry
fast, with **dequantization fused on read**, and add downstream processing
(composites, band-reduce/PCA over embeddings). The motivating pain: garry's
GDAL reader is slow on multi-band single-file COGs; `cptkirk` (Rust) is fast.

## The data: AEF embeddings

- Source Cooperative: `https://data.source.coop/tge-labs/aef/v1/annual/<year>/<mgrs>/...tiff`
  (also `/vsis3/.../opendata.source.coop/...`). Public, no auth.
- Per tile: **64 bands, 8192×8192, Int8, 1024² blocks, 13 overviews, ZSTD,
  native ~10 m** (downsampled to 30 m on the model grid). CRS = tile UTM (e.g.
  36S). **Stored SOUTH-UP** (positive N-S geotransform, `gt[6] = +10`) — GDAL
  warp handles it; `gdalbuildvrt` refuses positive NS, which is why hutan has a
  dedicated AEF path.
- **Dequant (nonlinear, per-value, sign-preserving):**
  `dequantize_aef(x) = ((x / 127.5)^2) * sign(x)`  (hutan `R/aef-helpers.R:27`).
  Int8 code ∈ [-127,127] → ~[-1,1]. Same 127.5 divisor for every band, no FSQ,
  no per-band scale/offset. In hutan it is a **separate post-warp Int8→Float32
  block pass** (`aef_decode_rast`), NOT fused into the read.

## cptkirk: how it reads fast (`/home/hugh/belian/cptkirk`)

"Thin pipe" between Rust `async-tiff` (saturated remote byte-range reads) and
GDAL (the warp). It does **no pixel math** — bytes only. Winning levers:
1. **One open per tile, all bands** — computes exactly which source tiles the
   warp window+overview touch; opens each source once (pooled).
2. **One global 16-way concurrent range-fetch pool** (`fetch_windows_pooled`,
   `buffer_unordered(io_concurrency)`, default 16; raise to 24-32 on fast links).
   Deliberately NO range coalescing — many small concurrent reads beat few big
   ones (coalescing benchmarked ~66s vs ~48s with a 235s tail).
3. **Native-dtype zero-copy staging**: streamed bytes → `/vsimem/*.bin` +
   `VRTRawRasterBand` `/vsimem/*.vrt` (Int8 stays 1 byte/px — no f32 bloat),
   then `gdalraster::warp()` consumes it.
4. **Overview selection** in R geometry (finest IFD with decimation ≤ target).
5. One TLS handshake per host; header read once (reused `cog_source` handle
   skips it).
6. **Planar band-SUBSET streaming**: for `INTERLEAVE=BAND` + no predictor,
   reading N of M bands fetches only N plane ranges (`band_fetch.rs`). Only
   helps for subsets — for a full 64-band read it's the one-open + concurrency +
   native staging that win.
- R API: `ck_warp()` (mosaic warp, batteries-included), `warp_remote()`
  (gdalraster::warp sibling), `ck_stack()` (fetch N sources → band-stack via
  `buildvrt -separate`), internal `cog_fetch_windows_raw()` (pooled raw fetch →
  native band-sequential bytes). Rust: `src/rust/src/{lib,window,band_fetch,
  http_reader,source,runtime,meta}.rs`, extendr wrappers.

## GDAL baseline (hutan) + garry's gap

hutan `R/aef-download.R` has three paths:
- `aef_warp()` — **one multithreaded gdalwarp, all 64 bands, one open**
  (`-multi -wo NUM_THREADS=4*cores`, GDAL_NUM_THREADS=ALL_CPUS). The *good* GDAL
  baseline.
- `aef_warp_bands()` (historical, removed in `a32b0f0`) — **mirai per-band
  fan-out**, one band per daemon, 64 warps, stitched `buildvrt -separate`. Slow
  (redundant header re-opens per band). The bench (`cptkirk/bench/aef-reprex.R`)
  compares cptkirk vs THIS.
- `aef_warp_ck()` (current) — delegates to `cptkirk::ck_warp`. hutan already
  switched its AEF loader to cptkirk.

**garry's structural gap:** garry's IR is **single-band per source**
(`lazy_source(path, band = 1L)`; warp-on-read `gdal_warp_to_buffer` is
`BANDS=1`, f32). A 64-band tile becomes 64 sources → **64 opens/warps**, each
producing f32. This is the `aef_warp_bands` failure mode — the "painfully slow"
download observed. garry as-is is the wrong tool for multi-band embeddings.

## Routing logic — SENSE-CHECKED, correct

Use cptkirk **only when a source file has >1 band we need to read**; plain GDAL
for single-band. Rationale (matches cptkirk's README AND Hugh's vrtility
testing — no advantage on single-band S2):
- cptkirk's only lever is I/O concurrency; a single-band file has no intra-file
  parallelism, and GDAL `/vsicurl` (HTTP/2 multiplex + multirange) already reads
  one plane well.
- garry's typical RS workload = N single-band assets over time; the parallelism
  is ACROSS ASSETS, which garry's daemon-parallel `/vsicurl` already exploits.
  cptkirk adds nothing there.
- cptkirk's win is ACROSS BAND PLANES within one multi-band file (embeddings).
- Refinement: true trigger = multi-band file AND ≥2 bands needed. Reading one
  band out of a multi-band file is a plain single-plane read → GDAL is fine.

## garry's differentiator: fused dequant-on-read

The nonlinear decode `((x/127.5)^2)*sign(x)` is a natural anvl `map` kernel:
`xn <- x/127.5; xn*xn * g_ifelse(x>0, 1, g_ifelse(x<0, -1, 0))`. garry fuses it
INTO the read/compute graph, on-device, distributed — and fuses whatever comes
next (composite, band-reduce/PCA). hutan runs it as a separate post-warp pass;
cptkirk can't do it at all. This is the thing garry adds on top of a fast read.

## DECISION & plan (updated 2026-07-15 per Hugh)

- **Do NOT integrate cptkirk into garry directly.** Instead: **add the
  multi-band reader capability to cptkirk**, and have **garry call cptkirk** as
  an external read engine for multi-band sources.
- garry keeps its read path for single-band assets (S2/HLS time series) — no
  change; that's where GDAL is already fine.
- Wiring inside garry (two options; leaning b):
  - (a) a new **multi-band source** concept (one source yields N bands), routed
    to the cptkirk engine.
  - (b) keep the single-band IR, and make the **read scheduler coalesce**
    sources that are N bands of the same file into ONE cptkirk fetch, then
    distribute the planes — analogous to garry's existing GTI/fetch coalescing.
    Keeps the IR uniform; only the reader gets smart.
- After cptkirk returns native bytes/warped buffer → garry uploads to anvl →
  fused dequant + downstream compute.

## OPEN QUESTION (Hugh): call the Rust/C++ directly?

Could garry bypass the R `cptkirk` layer and call the Rust crate (async-tiff +
the fetch pool + VRTRawRasterBand staging) directly? Assessment to do later:
- Simplest: garry depends on `cptkirk` (R pkg, Suggests) and calls
  `ck_warp` / `cog_fetch_windows_raw`. Zero Rust in garry (garry is pure-R
  today; adding a Rust toolchain/crate dep is a big step — parallels the
  gdalraster:::.get_data_ptr "pure-R vs compiled" tradeoff already in garry).
- Direct Rust linking (extendr in garry, or the crate as a shared lib) avoids an
  R round-trip but only worth it if the R boundary is a MEASURED bottleneck. The
  fetch is network-bound; the R↔Rust marshalling of native byte buffers is
  likely negligible vs the network. **Recommendation: call cptkirk (R) first;
  measure; only go direct-Rust if the boundary proves costly.**

## Benchmark to FINISH (needs a fast, idle link)

Script: `<scratchpad>/aef-read-compare.R` (one AEF tile, 2048² @ 30 m UTM-36S
window, near). Compares, on the SAME grid:
1. `cptkirk::ck_warp` (64-band).
2. one GDAL multi-band warp (all 64 bands) — garry's *potential* / hutan
   `aef_warp`.
3. 64× per-band GDAL warp — garry *as-is* (the slow one).
4. garry anvl dequant timing (expect ~free).
**The decisive comparison is (1) vs (2):** if one GDAL multi-band warp gets
close to cptkirk, garry may only need a native multi-band warp-on-read; if
cptkirk is well ahead, the cptkirk engine earns its place. Inconclusive so far
(slow link). Rerun idle + fast; take best-of-3; warm up first.

## Next steps

1. cptkirk: add/confirm a multi-band read entry point suited to garry's needs
   (native-dtype buffer out, band selection, window+overview).
2. Finish the benchmark on a fast link → decide native-multiband-warp vs
   cptkirk-engine (the (1)-vs-(2) call).
3. garry: read-scheduler coalescing (option b) to route multi-band same-file
   reads to cptkirk; keep single-band on GDAL.
4. garry: fused dequant map (`band_project`-style; the decode is elementwise) +
   demo a dequantized AEF stack → band-reduce/PCA (composes with the existing
   reduce-over-band work).
5. Decide the Rust-direct question by measurement, not up front.
