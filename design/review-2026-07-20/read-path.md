# Reviewer: read path (gdal_adapter.R, lazy_cog.R, read-task bodies)

## Experimental setup
Synthetic 512x512x72 Float32 GTiff created with garry's own default creation options (COMPRESS=DEFLATE only) reproduces production layout exactly: pixel-interleaved, 1-row strips (block 512x1), 72 MB uncompressed. GDAL_CACHEMAX=8 reproduces production window-bytes/cache ratio.

| mode | cache | time |
|---|---|---|
| one band, full window | 8 MB | 0.06 s |
| **72 per-band full-window reads (garry's shape)** | **8 MB** | **4.04 s** |
| 72 per-band reads, cache holds everything | 512 MB | 0.14 s |
| read_ds all 72 bands | 8 MB | 4.63 s |
| **band-blocked: all 72 bands per 8-row slab** | **8 MB** | **0.13 s** |

## Findings (ranked)

- **[performance] [critical] scheduler.R:112-140, 771-841 + gdal_adapter.R:152** — One read task = one band of one window → decompresses ALL bands' strips, keeps 1/145th; measured amplification = band count (72x: 4.04 s vs 0.056 s; band-blocked 0.13 s proves one pass serves all bands even with tiny cache). The handoff's "block cache + window-major keeps amplification near 1x" is FALSE at cohort scale: window's all-band bytes = 1916 rows × 8820 × 145 × 4 B ≈ 9.8 GB vs 256 MB per-daemon cache; sibling-band tasks also scatter across 8 daemons with private caches. Ballpark: one ESD year 13.2 GB uncompressed; 145 band-passes × ~4.6 column redundancy ≈ 8.8 TB decompress/year, ~114 TB over 13 years; at measured ~1.3 GB/s/core × 8 daemons ≈ 3 hours pure DEFLATE decode — consistent with run 5. Fix: multi-band read task per (file, window) reading all needed bands (dataset-level RasterIO or pure-R band-blocked loop via gdalraster, no C needed), one [band,y,x] region or N per-band regions. = handoff §3.2 / aef-multiband-read.md option (b). Impact: ~100-150x less decompress CPU; read tasks 15-20k → 150-400.

- **[performance] [high] passes.R:742-756, 794-798** — Square read windows on full-width-strip sources multiply decompression by column-chunk count (~4.6x): strips span full 8820-px width; ~5 column windows per row band re-decompress every strip. `.plan_chunk_dim` DISCARDS source block shape: x-axis LCM (8820) > 2*side (~958) so snapping bails to 1 (passes.R:752-754) → square chunks. Fix: when block is full-width strips (block_x == nx), make read windows full-width slabs (x = nx, y = read_px/nx). Orthogonal + composable with multi-band fix. ~4-5x on its own; free.

- **[architecture] [high] gdal_adapter.R:272-284** — garry's OWN sink writer creates the pathological files: `options = c("COMPRESS=DEFLATE")`, no TILED, no INTERLEAVE → pixel-interleaved 1-row-strip (verified: synthetic with these defaults reproduced production layout). hutan's non-garry writer uses INTERLEAVE=BAND, TILED=YES, 256x256 (hutan gdalraster-io.R:44, esd-helpers.R:147). Write-side twin: .exec_write_chunk (executor.R:357-389) streams chunk-width band-loop writes into full-width strips → read-modify-write recompression per strip per column chunk. Fix: default multi-band outputs to TILED=YES, BLOCKXSIZE=256, BLOCKYSIZE=256, INTERLEAVE=BAND, BIGTIFF=IF_SAFER. Rewriting existing cache is Hugh's call; fixing the default stops minting new ones.

- **[performance] [medium] scheduler.R:409, 429-433** — read_handles = 1L destroys residual block cache + thrashes handles across ~22 files interleaved by window-major order (each window ordinal spans ~2.4k tasks over ~22 files; every file transition discards cache). Depth-1 default was tuned for per-slice remote mosaics (docstring 397-402), not 13 local files revisited constantly. Fix: raise read-daemon handle depth ≥ concurrently-read files (e.g. 32) for local-file plans; open plain-GTiff handles are cheap (multi-GB pinning at gdal_adapter.R:29-32 was warped/GTI mosaics). Secondary to finding 1 but removes ~2k reopens. Gap: reopen cost on real 6 GB files unmeasured.

- **[performance] [medium] gdal_adapter.R:409 + no GDAL thread config** — per-daemon GDAL_CACHEMAX=256 too small to mitigate per-band reads AND collectively 2 GB across 8 daemons for zero benefit; no GDAL_NUM_THREADS → single-threaded DEFLATE per task. Fix: under multi-band task, size row slab to cache (self-tuning); optionally NUM_THREADS on local sources (unmeasured). Frees ~1.7 GB.

- **[performance] [medium] passes.R:781-785 (.plan_read_px)** — budget cap shrinks windows by sqrt(n_inputs): cap ≈ 3.7 Mpx vs 3.2e7 target = ~9x window-area cut = ~3x more column chunks against full-width strips. Budget prices residency, not decompress cost of cutting windows. Multi-band task dissolves the tension: one [145,y,x] region costs same residency as 145 per-band regions but one decompress pass → read_target_px can stay large. Rework budget logic WITH finding 1, not per-band.

- **[performance] [low-med] gdal_adapter.R:151-161** — per-read sentinel/NaN scans allocate 3-4 full-window temporaries (~60-90 MB/task, ~15k times); read body never gc()s (unlike compute body scheduler.R:230-233); `v[is.na(v) & !is.nan(v)] <- NaN` runs even when anyNA(v) FALSE. Fix: guard with anyNA / single combined pass. Small but free.

- **[correctness] [medium] lazy_cog.R:279-282 (.ck_mosaic_pinned, 946f5d0)** — pinning mosaic to full target grid makes uncovered area read 0, not NaN, when source declares no nodata sentinel: gdal_mosaic_vrt only sets -vrtnodata when length(vrtnodata) (gdal_adapter.R:250-251); GTI path deliberately sets -dstnodata nan for float targets (gdal_adapter.R:198-201, D8). Decoded embeddings contain exact zeros → gap indistinguishable from data. Fix: float dtype + empty nodata → vrtnodata = NaN. Not on bc hot path (embed/aef use lazy_source) but live for any partial-coverage lazy_cog mosaic.

- **[performance] [low] scheduler.R:705-710 + gdal_adapter.R:187-206** — warp VRTs built serially on host at task-build time, one gdalraster::warp per warp stage, tempfiles never cleaned; at 2.2k stages = minutes pre-launch + 2.2k VRTs in tempdir(). Not exercised by failing workload (aligned staged files, no WarpNodes — verified align() is only injector). gdal_warp_vrt is per-band (-b) so warped interleaved sources inherit amplification through the warper.

- **[performance] [low] scheduler.R:1082-1092** — window-major ordering comment encodes false cache assumption; ordering itself still right (enables unit release for multi-band task consumers). Doc fix.

- **[correctness] [info — no bug] executor.R:23-53, chunk_grid.R:108-132, executor.R:229-253** — edge/nodata semantics check out: halo windows clamp, beyond-edge stays NaN (D8), .exec_mask_edge re-NaNs ring after fused kernels, file NA + sentinel promote to NaN, raw path correctly gated halo-free f32, writeBin(size=4) rounds like C cast. Nits: (a) .exec_mask_edge on edge chunk materialises raw payload to 8 B/px double then shares as-is → edge chunks cost 2x booked store_mb (scheduler.R:758-761 assumes 4 B); (b) resampling on non-GTI lazy_source silently ignored outside .gti_resampled_path (scheduler.R:713).

- **[architecture] [high — the decision] aef-multiband-read.md:149-163** — unpause the plan in option (b) form, generalized beyond cptkirk: read-scheduler coalesces N same-file band sources into ONE fetch, distributes planes. For LOCAL interleaved files no cptkirk needed — band-blocked gdalraster loop (29x measured, cache-independent) or one dataset-level RasterIO. IR stays single-band; only .daemon_run_source_shm + task builder change: one task per (path, window) whose shared value is the per-band-keyed parts list consumers already know how to extract (parts/elt machinery scheduler.R:125-139 extends from spatial parts to band parts). Attacks handoff's top three suspects at once.

**Evidence gaps:** real cohort files unmeasured (grid math); mirai task→daemon placement reasoned not traced; GDAL MT strip decode + real-file reopen cost unmeasured; AEF staged nodata sentinel unverified.
