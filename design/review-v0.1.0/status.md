# v0.1.0 review: status of each finding

Numbers match `findings.md`. All 127 confirmed findings were worked through on branch `v0.1.0`; each fixed bug has a regression test, and fixes are in themed commits (see `git log`). Statuses below are fixed unless stated otherwise.


## Critical

- **1.** materialise() of a multi-band or multi-time LazyRaster silently keeps only band 1: Fixed.
- **2.** Source dedup ignores scale/offset/resampling: distinct reads silently merged into one: Fixed.

## High

- **3.** write_tif() keeps an integer source dtype after float arithmetic, so it rounds and clamps results that collect() returns correctly: Fixed.
- **4.** materialise() refuses any integer-typed plan, including a plain integer source: Fixed.
- **5.** write_tif(cog = TRUE) on grouped datasets without a {group} placeholder fails or overwrites, and leaks temp files: Fixed.
- **6.** .cd_spec routes multi-band stacks whose bands use different second operands or per-slice fns, then computes every band with band 1's F and fmask: Fixed.
- **7.** Integer overflow in the composite routing weight crashes collect() on large single-band composites: Fixed.
- **8.** Process-wide GDAL handle cache is never invalidated, so re-reading an overwritten file returns stale pixels: Fixed.
- **9.** South-up rasters are read vertically flipped on every non-warp read path (lazy_source, lazy_dataset file form without a grid, stage_raw_cube): Fixed.
- **10.** User-declared nodata is never passed to the warper: sentinels leak into resampled values, and cells outside the footprint read 0 instead of NaN: Fixed.
- **11.** align() to a LazyRaster with outer dims gives a 2-D warp a (x,y,t) grid: Fixed.
- **12.** Documented reduce ops prod/quantile/sd/var/any/all are accepted but fail at collect time: Fixed.
- **13.** Integer sources without nodata compute focal edges with 0 instead of NaN: Fixed.
- **14.** Nine exported names collide with terra/raster generics, and with both loaded the calls fail in both directions: Fixed.
- **15.** reduce_over() documents and accepts prod/quantile/sd/var/any/all, but none of them can execute: Fixed.
- **16.** A dead compute daemon makes every later collect() hang forever: Fixed.
- **17.** Coarse preview re-plan drops SourceNode scale/offset (and resampling), so previews show unscaled values: Fixed.
- **18.** preview(<file>, bands = ...) indexes the re-read bands with the original band numbers: crash or swapped RGB channels: Fixed.
- **19.** stac_query() end_date is effectively exclusive: acquisitions on the end date are dropped: Fixed.
- **20.** ds[[name]] <- value stores a (t,y,x) stack as one layer, breaking multi-slice datasets: Fixed.
- **21.** extract_points ignores the source band index, band subsetting, nodata and scale of a materialised cube: Fixed.
- **22.** sum/prod reductions keep small integer dtypes; written output clamps or overflows: Fixed.
- **23.** Scalar arithmetic on integer rasters keeps the integer dtype; write_tif truncates or rounds the float result: Fixed.
- **24.** Math group on a LazyDataset keeps the integer band dtype (sqrt/log written truncated): Fixed.

## Medium

- **25.** band_names argument is silently ignored for LazyDataset and LazyDatasetGroups, and its doc points at a collect() parameter that does not exist: Fixed.
- **26.** Masked full-grid band reduce overflows an integer byte count for large time cubes: Fixed.
- **27.** Multi-export write paths are not validated: an unnamed vector or a single file path gives 'subscript out of bounds': Fixed.
- **28.** FILTER open option is parsed by regex as a slice label; any other GTI filter breaks the default route: Fixed.
- **29.** Warp-on-read routes ignore the GTI SORT_FIELD/SORT_FIELD_ASC and always draw the latest datetime on top: Fixed.
- **30.** Warp-on-read ignores SourceNode@band, so multi-band GTI items fail (or become all-NaN) on the default route: Fixed.
- **31.** Exported gdal_read_window(scale = s) without offset silently returns an empty matrix: Fixed.
- **32.** Low-level adapter internals are exported as stable public API: Fixed.
- **33.** stage_raw_cube drops band scale/offset, uses band 1's nodata/dtype only, and flips south-up sources: Fixed.
- **34.** gdal_mosaic_vrt's skipped-source guard counts SourceFilename lines, which multi-band tiles inflate: Fixed.
- **35.** Exported extension API (fusable, is_barrier, FusedNode) is never consulted by the planner: Fixed.
- **36.** Exported S7 generics xmin/xmax/ymin/ymax/res mask terra/raster generics: Fixed.
- **37.** align() accepts any resampling string; typos surface as a GDAL failure at collect time: Fixed.
- **38.** focal() does not validate radius; negative/NA/vector radius fails later with an internal ChunkGrid error: Fixed.
- **39.** In-place band-stack collapse makes planning history-dependent (warp of a stack becomes a raw GDAL failure): Fixed.
- **40.** Plan-wide chunk snapping overflows integer LCM and crashes with mixed native block widths: Fixed.
- **41.** Gradient tape ignores NaN produced inside the pipeline (value NaN, grad silently wrong): Fixed.
- **42.** Gradient source reads ignore the source's resampling and GTI wrapping: Fixed.
- **43.** g_ifelse with a traced condition and two scalar branches errors: Fixed.
- **44.** Truncated safetensors payloads are silently recycled; OCM loading never verifies weight hashes: Fixed.
- **45.** Release metadata still says pre-release and experimental: Version bumped to 0.1.0; lifecycle kept "Experimental" by decision.
- **46.** Lazy objects have no names()/length()/dim()/$ support, so the docs reach into @ slots: Fixed.
- **47.** ocm example calls reduce_over() with the arguments swapped and a nonexistent axis: Fixed.
- **48.** Internal plumbing exported under public-looking names: Fixed.
- **49.** plan_view example and the Inspecting plans article build a focal pipeline that cannot execute: Fixed.
- **50.** Inconsistent argument names across sibling public verbs: Fixed.
- **51.** write_tif() leaves a partially written destination file when execution fails: Fixed.
- **52.** Only 5 of 177 Rd pages have examples, and 4 of those are \dontrun: Fixed.
- **53.** cgroup limit read only from the leaf cgroup; ancestor limits (SLURM job, systemd slice) are ignored: Fixed.
- **54.** cgroup headroom counts reclaimable page cache as used memory, flooring every budget in confined runs: Fixed.
- **55.** garry.daemon_gc_mb never reaches the daemons it configures: Fixed.
- **56.** run_id is drawn from the user's RNG stream, so collect() changes .Random.seed and seeded sessions collide on the fetch directory: Fixed.
- **57.** Eager fetch-cache unlink is per stage, but fetched files are shared across stages: Fixed (files refcounted across stages); the race did not reproduce in a test, so the new test pins the scenario rather than proving the fix.
- **58.** garry_task_report merges launch/done rows by key, producing a cross product for logs that span several runs: Fixed.
- **59.** preview() of a file reads every requested band at full resolution before decimating: Fixed.
- **60.** stac_sign_mpc() signs every item with the first item's collection token: Fixed.
- **61.** Token cache returns tokens with seconds left, which defeats .mpc_resign()'s expiry margin: Fixed.
- **62.** Antimeridian-crossing STAC items are rejected outright: Partial: antimeridian-crossing items now get a clear error. Indexing them (split footprints) is not implemented.
- **63.** Items with null `datetime` are silently dropped from stacks and datasets: Fixed.
- **64.** No tests for the risky preview/STAC paths found above: Fixed.
- **65.** Dataset verbs accept unknown band names and silently create empty or NA bands: Fixed.
- **66.** reduce_over(ds, op, "band") folds the QA/mask band into the band reduction: Fixed.
- **67.** Exported mask() and grid accessor generics mask terra/dplyr functions: Fixed.
- **68.** Unary minus, !, &, |, %/%, Summary and logical scalars on LazyRaster fail with opaque errors: Fixed.
- **69.** Comparison operators turn nodata (NaN) into a valid 0: Fixed.
- **70.** align() accepts targets and inputs it cannot honour; default resampling differs from the readers: Fixed except the default resampling (`bilinear` vs the readers' `near`): an API decision left open.

## Low

- **71.** collect() results never carry band names, so as_terra()'s promise to preserve names is never met: Fixed.
- **72.** garry.daemon_gc_mb is read only on daemons but never shipped to them: Fixed.
- **73.** Daemon task bodies are exported, dot-prefixed functions in the stable public namespace: Fixed.
- **74.** Writer close errors are discarded, so a failed final flush can report a successful write: Fixed.
- **75.** Dead or stale code in the daemon and executor layer: Fixed.
- **76.** write_tif() returns the directory, not the per-sink files, for the directory form, contradicting @return: Fixed.
- **77.** Integer writes silently saturate out-of-range values, which can then collide with the nodata sentinel: Fixed in part: quantized values no longer saturate onto a nodata limit, and saturation is documented. No count of saturated pixels is reported.
- **78.** write_tif() validation gaps: u32 quantization accepted then fails deep; nodata length, type and integrality unchecked: Fixed.
- **79.** COG docs promise 'path never holds a half-written COG', but the translate writes directly to path: Fixed.
- **80.** An aborted pipeline leaves fetch/compute tasks running and reuses the same per-pid tmp dir on the next run: Partial: each run gets a fresh scratch dir, so orphans cannot overwrite the next run. Cancelling orphaned tasks needs a dispatcher, which these pools do not have.
- **81.** read_fail = 'nodata' does not hold on the gd routes when a fetch task dies, and the fmask progress line crashes on failed tasks: Fixed.
- **82.** Pipeline does not check the mask task result before dispatching band tasks: Fixed.
- **83.** Raw-cube VRT XML interpolates band names, CRS and nodata without escaping: Fixed.
- **84.** Raw-BSQ fast read does not bounds-check the window and returns short or zero-padded payloads: Fixed.
- **85.** .vrt destinations silently drop scale/offset and creation options: Fixed.
- **86.** Dead helper and stale route comments/docs: Fixed.
- **87.** cross_grid_window() is exported but unused by the package: Fixed.
- **88.** graph_import does not remap SourceNode@collapsed ids: Fixed.
- **89.** grid_equal ignores dim names, so t-stacks and band-stacks of equal length compare equal: Fixed.
- **90.** FocalNode docs list boundary policies that do not exist: Fixed.
- **91.** Stale comment: band-stack collapse claims to skip sink stacks but does not: Fixed.
- **92.** garry_explain_placement(): empty table lacks the `tiles` column and docs omit it: Fixed.
- **93.** OCM default weights lookup and download are fragile: Fixed.
- **94.** OCM weight cache can serve stale folds after a garry upgrade: Fixed.
- **95.** Exported ops whose pure-R oracle disagrees with or cannot run the traced path: Fixed.
- **96.** Leftover capability gates and dead variable: Fixed.
- **97.** Kalman regime with no observations emits the previous regime's extrapolated level: Fixed.
- **98.** kalman_smooth(LazyDataset, obs_var = ...) fails with an unrelated class error: Fixed.
- **99.** CI never tests the declared minimum R version: Fixed.
- **100.** gdalraster floor is a dev version with an unpinned GitHub Remote, though CRAN 2.7.0 has the needed API: Fixed.
- **101.** Grid-mismatch error suggests an align() signature that does not exist: Fixed.
- **102.** align() and lazy_source() accept any resampling string; bad values fail only inside GDAL at collect(): Fixed.
- **103.** Capability probes and anvl guards are dead code because anvl is a hard Import: Fixed.
- **104.** Exported functions with no test reference, and no test pinning the documented reduce ops: Fixed.
- **105.** Integer option validator throws an unclassed base error for large values: Fixed.
- **106.** Mixed routed scan shaping leaves the scan daemons on half-machine masks for all later plans: Fixed.
- **107.** garry_daemons docs claim every daemon gets a disjoint CPU slice; read and compute masks overlap: Fixed.
- **108.** garry_daemons() does not validate read/compute/read_handles, and '...' conflicts with the hard-coded dispatcher: Fixed.
- **109.** Compute task working-set estimate is not clipped to the grid, unlike the store and warm-up estimates: Fixed.
- **110.** garry_task_report crashes on a log with no completed tasks: Fixed.
- **111.** 'peak fleet anon RSS' in the task report is effectively a single-daemon peak: Fixed.
- **112.** plan_view() tooltips embed raw source paths, including SAS tokens, unescaped in HTML: Fixed.
- **113.** preview() rejects 4D collected arrays with an opaque error and silently shows a time stack as RGB: Partial: arrays of rank > 3 are refused clearly. A (y, x, t) array is still drawn as RGB when it has 3 slices.
- **114.** preview() swallows misspelled arguments through `...`: Fixed.
- **115.** stac_query() falls back to POST on any GET error, hiding the real failure; docs promise lubridate parsing: Partial: bbox and dates are validated up front, and a GET-then-POST failure reports both errors. The fallback still fires on any GET error, and 429/5xx are not retried.
- **116.** Re-signing an href strips any non-SAS query parameters: Fixed.
- **117.** MPC token cache: no retry on the token request and non-atomic writes to a file shared by daemons: Fixed.
- **118.** stac_sources() crashes with a cryptic error when no item carries the requested assets: Fixed.
- **119.** lazy_stac_stack() is a second exported STAC entry point that lags behind lazy_dataset(): Fixed.
- **120.** as_dataset / lazy_map give opaque errors on non-LazyRaster input and skip grid checks across bands: Fixed.
- **121.** group_by_time docs say collect() writes per-group files via `path`, but collect has no path argument: Fixed.
- **122.** fill_gaps on a LazyDataset errors when any value band has a single slice: Fixed.
- **123.** qa_bits double-counts repeated bits, producing the wrong bitmask: Fixed.
- **124.** draw() on a LazyRaster is exponential in shared subgraphs: Fixed.
- **125.** time_sel/band_sel silently ignore prefix selectors when any exact label matches: Fixed.
- **126.** round(x, digits)/signif with extra args build fine but fail at collect with a base error: Fixed.
- **127.** focal() does not validate radius: Fixed.
