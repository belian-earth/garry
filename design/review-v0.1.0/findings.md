# garry v0.1.0 pre-release review

Eight subsystem reviewers read the package in full on branch `v0.1.0` (2026-10-02); a second agent per subsystem tried to refute each finding against the code. 129 findings: 127 confirmed, 2 refuted (listed at the end). Spot-checked by hand: source dedup (critical), materialise of a band stack (critical), STAC end date (high) all reproduce.

## Subsystem summaries

**ir-planning.** The IR and planner core (fusion, D22 pad propagation, merge pass, chunk/halo geometry) is internally consistent, and the pad walk matches its static mirror. The serious defects sit at the edges. Source dedup in graph_import ignores scale/offset/resampling and returns wrong values (reproduced: 2 where the correct sum is 3). The in-place band-stack collapse makes later plans depend on earlier collects. grid_from_src shifts native raster grids by up to half a pixel. align() to a stacked target breaks the grid/value invariant. For the stable API, six of the twelve documented reduce ops cannot execute, focal and align arguments are unvalidated, the xmin/res generics collide with terra, and fusable/is_barrier/FusedNode/cross_grid_window are exported but unused by the engine.

**scheduler-pools.** The scheduler's dispatch, harvest and refcount logic is careful and internally consistent: the escape hatches prevent the gates from deadlocking, the writer abort handler is correctly prepended, and per-profile warmth tracking is sound. The real defects are at the edges. A compute daemon that dies leaves a dead width-1 profile that hangs every later collect(). The cgroup memory probe counts reclaimable page cache as used and reads only the leaf cgroup, so confined runs collapse to near-serial execution. Some host options and diagnostics silently do not reach, or misreport, what they claim to: daemon_gc_mb never reaches the daemons, run_id consumes the user's RNG, and the task report merges and sums incorrectly.

**executor-daemons.** The executor and daemon layer is careful about store lifetimes, writer abort ordering and C bounds checks; store.c and trim.c showed no memory-safety defects. The serious problems sit at the user entry points. materialise() silently drops every band but the first of a multi-band raster and refuses integer plans. write_tif() writes integer-source arithmetic in the source's integer dtype, so the file differs from collect(). COG output for grouped datasets mishandles its paths. A further set of medium issues: unvalidated paths and nodata, ignored band_names, silent integer saturation, an integer overflow in the composite mask read, and swallowed writer close errors.

**gdal-io.** The GDAL adapter and the composite-direct pipeline work on the common case the tests cover: north-up GTiffs whose nodata is declared in the file, and the canonical HLS masked composite. Outside that case there are several silent wrong-result bugs on default routes, each confirmed by running a probe. (1) .cd_spec applies band 1's mask/second operand and per-slice function to every band. (2) South-up rasters are read upside down whenever no warp is involved. (3) A nodata value the user declares but the file does not is never passed to the warper. (4) The handle cache returns stale data after a file is overwritten. (5) The warp-on-read route ignores sort_field. There are also crash paths: integer overflow in the routing weight and custom GTI FILTERs. The remaining findings are API, metadata and robustness gaps that should be settled before v0.1.0.

**user-api.** The user-API layer is coherent, but its dtype bookkeeping disagrees with what the kernels compute. Integer rasters keep their integer dtype under float scalars, sum/prod, and Math on datasets. In-memory collect() hides this, while write_tif()/materialise() silently truncate or clamp the written values: wrong data on disk in normal use. Other real defects: extract_points ignores band selection, nodata and scale for materialised cubes. Comparisons turn nodata into valid zeros. ds[[<-]] on multi-slice datasets breaks later verbs. Dataset verbs, time_sel, focal radius and qa_bits lack input validation. draw() is exponential on shared subgraphs.

**stac-views.** The STAC layer is well structured: rectangularising into a plain table works well, and filters, rename and merge behave as documented on the happy path. Two time and auth handling defects need fixing before v0.1.0. stac_query treats a date-only end_date as midnight, so the last day's acquisitions are silently dropped. MPC signing uses a single collection token for merged collections, and its cache ignores the expiry margin that re-signing depends on. On the views side, plan_view showed no correctness problems. preview has two wrong-output bugs: explicit bands on a file are indexed against the compacted array, and the coarse re-plan drops source scale/offset. Neither is caught by the current tests.

**kernels.** The kernel subsystem is numerically sound where tests reach it. Kalman, Hampel, OCM and the reshape bridges match their oracles; I re-checked Kalman with boundaries and robust passes, traced against oracle, to about 5e-7. Two high-severity wrong-result bugs sit outside test coverage. First, g_upload zero-fills the NaN edge halo for integer sources that have no nodata, so focal results at raster edges depend on the file's storage dtype. Second, the gradient mask ignores NaN produced inside the pipeline, so the loss value is NaN and the mean gradient uses the wrong count. Medium issues: the gradient path ignores source resampling, the safetensors reader recycles truncated payloads silently, g_ifelse crashes when traced with two scalar branches, and a Kalman regime with no observations leaks the previous regime's level.

**package-docs.** The package metadata and docs are internally consistent at the mechanical level. Every export is documented, every non-internal topic is in the pkgdown index, Collate matches R/, the start-first test names resolve, and the prerendered vignettes match their .orig sources. The serious problems are in the API surface that v0.1.0 would freeze. Six reducers that reduce_over() documents and accepts at build time fail at collect(). Nine exported names collide with terra/raster generics, and once both packages are loaded the calls fail in both directions. LazyDataset/LazyRaster have no names()/length()/dim()/$ support, so the vignettes reach into @ slots. Release metadata (version 0.0.0.9000, "Experimental", no NEWS.md, a gdalraster dev floor plus GitHub Remotes) still describes a pre-release package.

## Critical (2)

### 1. materialise() of a multi-band or multi-time LazyRaster silently keeps only band 1
`R/materialise.R:81` · executor-daemons · bug

**Problem.** The LazyRaster branch writes every band of the sink into the .vrt/.bin cube, then returns lazy_source(path). lazy_source() defaults to band = 1L, so a (band, y, x) or (t, y, x) raster comes back as a single 2-D layer. All downstream work then runs on band 1 with no error or warning. The named-list branch (line 100, lapply(paths, lazy_source)) has the same defect. This contradicts the documented contract that materialise returns 'the SAME KIND of lazy object' and that 'everything downstream continues unchanged'.

**Evidence.** Checked with load_all: s <- lazy_stack(list(a=x*1,b=x*2,c=x*3), along='band') has dims x=20,y=10,band=3. materialise(s, ...)@grid@dims is x=20,y=10, and collect() of the result is a 10x20 matrix. A t-stack of 2 slices also comes back as x/y only.

**Suggested fix.** When the sink grid has an outer dim, reopen every band: lazy_source(path, band = seq_len(nb)), or lazy_stack over per-band sources with the outer dim's name and labels. Do the same in the named-list branch, and add a test that round-trips a multi-band raster through materialise().

**Verifier.** Reproduced with load_all. lazy_stack(list(a,b,c), along='band') on an f32 source has dims x=20,y=10,band=3. materialise() returns lazy_source(path) with the default band=1L (materialise.R:81, lazy_raster.R:105), and the result's dims are x=20,y=10; collect() gives a 10x20 matrix. The list branch at line 100 uses lapply(paths, lazy_source) and has the same defect. This contradicts the 'SAME KIND of lazy object' contract.

### 2. Source dedup ignores scale/offset/resampling: distinct reads silently merged into one
`R/graph.R:325` · ir-planning · bug

**Problem.** `.source_identical()` (and the bucket key `.source_key()`) compare only path, band, nodata, open_options, grid and dtype. `graph_import()` therefore treats two SourceNodes on the same file as one read even when they differ in `scale`/`offset` (the band affine applied in the read kernel) or `resampling` (the read-time resampler onto a non-native grid). Any binary op across graphs then rewires the second operand to the first one's source, so the second operand gets the first one's affine or resampler.

**Evidence.** Checked: `a <- lazy_source(f, nodata=-1, scale=0.5, offset=0); b <- lazy_source(f, nodata=-1); s <- a + b` produces a graph with ONE SourceNode (scale 0.5) and `MapNode(parents = 1 1)`. With the file filled with 2s, `collect(s)` returns 2 where the correct value is 0.5*2 + 2 = 3. The same happens for `lazy_source(f, grid=g2, resampling='bilinear') + lazy_source(f, grid=g2, resampling='near')`: one bilinear source, used twice.

**Suggested fix.** Add `identical(a@scale, b@scale) && identical(a@offset, b@offset) && identical(a@resampling, b@resampling)`, and arguably `a@band` length and `a@collapsed`, to `.source_identical()`, and include scale, offset and resampling in `.source_key()`. Add a regression test that imports same-path sources differing only in scale or resampling.

**Verifier.** .source_identical() and .source_key() (R/graph.R:279-332) compare path, band, nodata, open_options, grid and dtype only. Reproduced with lazy_source(f, scale=0.5, offset=0) + lazy_source(f): the graph has one SourceNode and one MapNode, and collect returns 101 where 151.5 is correct (both operands get the 0.5 scale). Silent wrong result in normal use.

## High (22)

### 3. write_tif() keeps an integer source dtype after float arithmetic, so it rounds and clamps results that collect() returns correctly
`R/executor.R:828` · executor-daemons · bug

**Problem.** When dtype is NULL, the output dtype is sink@grid@dtype (here and in the scheduler's gdal_create_output). Map nodes inherit their parent's dtype, so lazy_source(u16) * 1.5 or lazy_source(u16) - 100 is still tagged 'u16'. collect() returns the true doubles (1.5, 3.0, ..., -99), but write_tif() creates a UInt16 GTiff. GDAL then rounds the fractions and clamps negatives to 0, with no warning. The same plan writes different numbers than it collects. Two more symptoms: if the source has nodata, write_tif() without a nodata argument aborts with 'no nodata sentinel ... for integer output dtype' although the user never asked for an integer output; and collect()'s gis$datatype reports 'UInt16' for float results. The docs say the default 'keeps the plan's dtype (usually f32)', which is not what happens for integer sources.

**Evidence.** x <- lazy_source(u16.tif) * 1.5; x@grid@dtype is 'u16'; collect gives 1.5 3.0 4.5. write_tif(x, 'def.tif') writes a UInt16 file whose values read back as 2 3 5 6 8 9. (lazy_source(f) - 100)@grid@dtype is 'u16' and collect's range is -99..100.

**Suggested fix.** Promote the dtype of float-producing map/reduce nodes to f32 in the planner. At the sink, use f32 as the default output dtype unless the user passes dtype. Add an equivalence test that write_tif() then read_ds() equals collect() for an integer source with float arithmetic.

**Verifier.** Reproduced: a u16 GTiff with no nodata, lazy_source(f)*1.5 has dtype 'u16'. collect() gives 1.5, 31.5, 61.5, but write_tif() writes UInt16 values 2, 3, 5. The dtype falls back to sink@grid@dtype (executor.R:828; gdal_create_output gets wspec$dtype=NULL). Downgraded from critical: lazy_source retypes to f32 whenever nodata or scale is present (lazy_raster.R ~146-151), so the defect hits only integer sources without nodata or scale. That same retype refutes the sub-claim that a nodata source makes write_tif abort for integer output.

### 4. materialise() refuses any integer-typed plan, including a plain integer source
`R/materialise.R:80` · executor-daemons · api

**Problem.** materialise() always writes a .vrt raw cube. .raw_cube_create() aborts unless grid@dtype is f32/f64, and the grid dtype of an unscaled integer source (and, per the finding above, of arithmetic on it) is the integer dtype. Checkpointing lazy_source('dn_u16.tif') or any graph built on it therefore fails with 'raw cubes hold f32/f64 only ... write a .tif for integer outputs'. materialise() has no dtype or format argument, so the user has no way around this. The docs present materialise() as the general checkpoint verb.

**Evidence.** materialise(lazy_source(u16.tif), dir=..., distributed=FALSE) returns the error "raw cubes hold f32/f64 only (got \"u16\"); write a .tif for integer outputs".

**Suggested fix.** Write integer plans as an f32 cube (the in-memory compute dtype), or support integer raw cubes in .raw_cube_create and .gdal_finish_vec. Either way, document the dtype the checkpoint is stored in.

**Verifier.** Reproduced: materialise(lazy_source(u16.tif)) aborts with 'raw cubes hold f32/f64 only (got "u16"); write a .tif for integer outputs' from .raw_cube_create. materialise() has no dtype argument. The only workaround is indirect: pass nodata or scale to lazy_source so it retypes to f32.

### 5. write_tif(cog = TRUE) on grouped datasets without a {group} placeholder fails or overwrites, and leaks temp files
`R/write_tif.R:203` · executor-daemons · bug

**Problem.** For a single path without a placeholder, work is one tempfile 'garry-cog-XXXX.tif'. .collect_groups then inserts each group label, so it actually writes 'garry-cog-XXXX_<label>.tif' per group and returns those paths. finals falls through to the final branch, path, which has length 1. The COG loop translates streamed[[1]] onto path (with no group label) and then fails with 'subscript out of bounds' at finals[[2]]. The on.exit unlinks only the original work name, which never existed, so every per-group temp GeoTIFF is left beside the target. With a single group the call 'succeeds', but it still leaks the temp file and names the output without the label that the non-COG route would add. A placeholder in the directory part (e.g. 'out/{group}/x.tif') is mishandled the same way: work uses basename(path), and finals gets a literal '{group}' directory.

**Evidence.** Line 174 sets work <- tempfile(...) for a non-dir, non-placeholder path. collect.R:255-258 and .group_paths insert labels when no placeholder is present. Line 209-210: `} else { path }`. Line 226 indexes finals[[i]] for i in seq_along(streamed). Line 181 unlinks only `work`.

**Suggested fix.** Compute finals from the same .group_paths expansion applied to the real path (match streamed to work by group label). Unlink the actually-streamed files in on.exit, not just `work`. Add tests for cog = TRUE with LazyDatasetGroups in both the placeholder and no-placeholder forms.

**Verifier.** Traced in code. For a non-dir, non-placeholder path, work is a single tempfile (write_tif.R:174-178). .collect_groups/.group_paths insert '_<label>' (collect.R:312-321) and return those paths. finals falls to `path`, which has length 1 (write_tif.R:209-210), so the loop at line 226 hits finals[[2]], giving subscript out of bounds after the full compute. on.exit unlinks only `work`, which never exists, so the per-group temps leak. With a single group the call succeeds but leaks the temp and drops the label. A '{group}' placeholder in the directory part produces a literal-brace tmpdir and work without a placeholder, so labels are inserted into the temp name instead.

### 6. .cd_spec routes multi-band stacks whose bands use different second operands or per-slice fns, then computes every band with band 1's F and fmask
`R/composite_direct.R:315` · gdal-io · bug

**Problem.** The cross-band check compares only op, nan_rm, whether the mask chain is empty and, when the chain is non-empty, the fmask ids. It never compares s$F or s$mask_chain across bands. When the per-slice second parent is a bare SourceNode (empty chain), masked=FALSE, so the fmask ids are not compared either. The returned spec keeps only s1$F, s1$mask_chain and s1$fmask, and both .execute_composite_direct and .gd_reduce_results apply them to every band. Example: lazy_stack(list(mean_t(A - B), mean_t(A * C)), along = 'band') goes to composite_direct, and band 2 is silently computed as mean_t(A - B). The same happens to masked composites whose bands share a QA source but use different mask cleaning or masked-apply fns. Default route (composite_direct = TRUE, gd_parallel either way).

**Evidence.** Probe on local GTIs: .cd_spec(p) returned fmask_srcs = c(3,4) (the B slices) and F = function(x, y) x - y for both bands. The oracle gave band2[1,1] = 4014. collect(distributed = TRUE) gave route 'composite_direct' and band2[1,1] = -70 (equal to band 1), for both gd_parallel = TRUE and FALSE.

**Suggested fix.** In the `ok` vapply, also require identical(.cd_fn_sig(s$F), .cd_fn_sig(s1$F)), identical(.cd_chain_sig(s$mask_chain), .cd_chain_sig(s1$mask_chain)) and identical(s$fmask, s1$fmask) unconditionally, not only when masked. Plans that fail this fall to .gd_decompose, which already groups by F and chain hash. Add a heterogeneous-band equivalence test.

**Verifier.** Verified in code: .cd_spec's cross-band check (composite_direct.R:315-325) compares only op, nan_rm, whether the mask chain is empty and, when masked, the fmask ids. It never compares F or the chain signature. The returned spec carries only s1$F, s1$mask_chain and s1$fmask. The per-slice homogeneity check in .cd_reduce_spec runs within a band, not across bands. The gd_reduce route does group by an F and chain hash (L1264-1281), so that route is correct and the bug is confined to composite_direct. The result is silently wrong, but it needs bands with different per-slice fns or mask cleaning, which is less common than a shared mask. Downgraded to high.

### 7. Integer overflow in the composite routing weight crashes collect() on large single-band composites
`R/composite_direct.R:339` · gdal-io · bug

**Problem.** GridSpec dims are integer, so `(n_bands + (s1$halo > 0L)) * n_slices * grid_px` is integer arithmetic. It overflows to NA once the product passes 2^31, for example a 3660x3660 HLS tile (13.4M px) with 160 slices. For n_bands == 1 the guard becomes `if (NA && TRUE)`, which errors with 'missing value where TRUE/FALSE needed'. collect(distributed = TRUE) then aborts during routing on exactly the heavy plans the budget exists to divert. A related overflow sits in the pipeline's whole-band task: daemon.R `readBin(k$mask_bin, 'raw', n = n * k$ny * nx * 4L)` gives NA once the mask cube passes 2 GB when ns == 1.

**Evidence.** Rscript check with dims from grid_spec(..., res = 30) over 164700 m: w = (1L + FALSE) * 100L * dims['x'] * dims['y'] gives NA with 'NAs produced by integer overflow', and the routing `if` errors with 'missing value where TRUE/FALSE needed'.

**Suggested fix.** Compute in double: grid_px <- as.numeric(dims[['x']]) * dims[['y']] (likewise weight), and use as.numeric() for every byte count passed to readBin in the pipeline tasks.

**Verifier.** GridSpec dims are integer (checked). A 3660x3660 grid gives grid_px = 13,395,600 (integer), and length() is integer, so (1L+FALSE)*161L*grid_px overflows to NA. With n_bands == 1 the condition is NA && TRUE, which errors in if(). 160 slices sit just under 2^31, so a year of HLS L30+S30 on a full tile crosses the limit. daemon.R:956 has the same integer product (n*ny*nx*4L) when the mask cube is read whole.

### 8. Process-wide GDAL handle cache is never invalidated, so re-reading an overwritten file returns stale pixels
`R/gdal_adapter.R:84` · gdal-io · bug

**Problem.** .gdal_handle() keys only on path plus open options and returns the cached GDALRaster with its block cache and file descriptor. Nothing in the package calls .gdal_handle_reset() (only tests do), and gdal_create_output/write_tif do not evict the destination path. Writing an output, reading it, then rewriting the same path in the same session (normal iterative use: write_tif then lazy_source on the result) returns the first version's data. The same applies on long-lived read daemons.

**Evidence.** Probe: gdal_create_output(p) writes 1, then gdal_read_window reads 1. Rewriting p with 2 via gdal_create_output/gdal_write_window and reading again with gdal_read_window or collect(lazy_source(p)) still returns 1.

**Suggested fix.** Key the cache on file mtime/size for local paths (as .raw_vrt_info already does), and/or evict the path's entries in gdal_create_output() and gdal_open_update(). Broadcast an eviction to read daemons after a write.

**Verifier.** Reproduced. After overwriting a file, collect(lazy_source(f)) and gdal_read_window still return the old value (1 instead of 7). Nothing outside tests calls .gdal_handle_reset, and no write path evicts the cache. Worse: write_tif(x+1, out), then collect(lazy_source(out)), then write_tif(x+5, out) leaves 2 ON DISK (a fresh GDALRaster reads 2). The same sequence without the intermediate read writes 6. So the stale cached handle also corrupts the rewrite: data loss in a normal iterative workflow.

### 9. South-up rasters are read vertically flipped on every non-warp read path (lazy_source, lazy_dataset file form without a grid, stage_raw_cube)
`R/gdal_adapter.R:185` · gdal-io · bug

**Problem.** gdal_grid_spec() rewrites a south-up geotransform (gt[6] > 0) into a north-up GridSpec with the same footprint. gdal_read_window() and .gdal_read_window_bands() still read rows in the file's own order, so file row 1 (southernmost) becomes garry row 1 (labelled northernmost). Only the warper paths reorient. .rio_direct_spec() rejects south-up, and gdal_warp_vrt/gdal_warp_window handle it. Any unwarped read is therefore upside down: lazy_source(path), lazy_dataset(single_file) without `grid`, align() to the source's own grid (short-circuited by grid_equal), and stage_raw_cube(). The comment at L175 names AEF embedding COGs as south-up, so this is the normal case for that product.

**Evidence.** Probe: a 4x3 Float32 GTiff with gt = c(0,10,0,0,0,10) and file rows 1/2/3 = 1/2/3 (row 3 northernmost). collect(lazy_source(f)) and collect(lazy_dataset(f)) both return row 1 = 1, row 3 = 3, while the gis bbox/transform declare row 1 as the north edge.

**Suggested fix.** Return an orientation flag from gdal_grid_spec(), carry it on SourceNode, and in gdal_read_window/.gdal_read_window_bands/.raw_vrt_read map the window to y_off' = ny - y_off - y_size and reverse rows after reading. Alternatively, route south-up sources through the warp path at construction. Add a south-up equivalence test against a warped read.

**Verifier.** Reproduced with a south-up GTiff (gt = c(0,10,0,0,0,10)): collect(lazy_source(f)) returns file row 1 (the southernmost, y in 0..10) as row 1, while gis/GridSpec declare a north-up transform with row 1 at ymax. gdal_grid_spec (L174-197) normalises the transform, but gdal_read_window reads rows in file order. Its own roxygen (L367) promises 'row 1 = northernmost'. Warp paths are unaffected. Rated high rather than critical because typical AEF use pins a grid, which forces the warper.

### 10. User-declared nodata is never passed to the warper: sentinels leak into resampled values, and cells outside the footprint read 0 instead of NaN
`R/gdal_adapter.R:1087` · gdal-io · bug

**Problem.** gdal_warp_vrt() adds `-dstnodata nan` only when src_nodata is empty, and never passes `-srcnodata`. When the SourceNode nodata comes from the user (lazy_source(nodata=), lazy_dataset(nodata=)) and the file declares none (or a different value), two things go wrong. (a) Bilinear, cubic and average resampling blend the sentinel into neighbouring cells, and .gdal_finish_vec only promotes exact matches to NaN. (b) Target cells outside the source footprint are initialised to 0 and read as valid zeros. The decimating fast path (.rio_direct_spec, L277) has the same blind spot: RasterIO AVERAGE honours only file-declared nodata. gdal_warp_to_buffer (composite route) does pass -srcnodata, so the routes disagree.

**Evidence.** Probe: a 4x4 file without nodata, all values 100 except one -9999 cell, read with lazy_source(f, nodata = -9999). align() to a larger extent with near gives 0 in every outside cell. align() to 5 m with bilinear gives values of -531, -1794 and -5581 around the sentinel.

**Suggested fix.** When src_nodata has length 1, pass c('-srcnodata', v, '-dstnodata', v) (or 'nan' for float targets with the sentinel mapped later). For .rio_direct_spec, decline the fast path for non-NEAREST resampling when the node nodata differs from the band's file nodata.

**Verifier.** gdal_warp_vrt (L1087-1092) adds -dstnodata nan only when src_nodata is empty and never passes -srcnodata. lazy_source(nodata=) overrides the file metadata (lazy_raster.R ~L123), so a user-declared sentinel on a file with no declared nodata is unknown to the warper. Resampling blends it, and cells outside the footprint get 0. gdal_warp_to_buffer (L1475-1478) does pass -srcnodata and always sets dstnodata nan, so the routes disagree. When the file declares its own nodata, gdalwarp propagates it and the read is fine.

### 11. align() to a LazyRaster with outer dims gives a 2-D warp a (x,y,t) grid
`R/lazy_raster.R:1106` · ir-planning · bug

**Problem.** `align()` takes the whole target GridSpec, outer dims included, from `to`. Aligning a 2-D raster to a (x,y,t) stack yields a WarpNode whose grid claims t=N while the warp produces a single plane. The IR invariant 'node grid describes node value' is broken. `grid_equal()` then lets the binary op through, and it crashes deep in anvl. Because `grid_equal` compares dims length, a spatially identical target also never takes the paste fast path.

**Evidence.** Checked: `a <- align(b1, st)`, with st a 2-slice t stack on the same spatial grid, gives `a@grid@dims` = x 10, y 10, t 2. `collect(a)` returns a 10x10 array. `collect(a + st)` fails inside anvl::nv_add with 'All non-scalar arrays must have the same shape, but got (10x10), (2x10x10)'.

**Suggested fix.** In `align()`, build the target from `to`'s spatial geometry only: CRS, transform, extent and x/y dims, keeping `x`'s own outer dims and labels. Compare with `.spatial_equal` for the paste fast path.

**Verifier.** align() (R/lazy_raster.R:1102-1118) takes to@grid whole. Reproduced: align(lazy_source(f), t-stack) has dims x 60, y 40, t 2, and collect(x + st) crashes inside anvl::nv_add with a shape mismatch of (40x60) against (2x40x60). The node grid no longer matches the node's value, and the user gets an internal crash.

### 12. Documented reduce ops prod/quantile/sd/var/any/all are accepted but fail at collect time
`R/passes.R:41` · ir-planning · api

**Problem.** `reduce_over()` documents 12 ops, and the ReduceNode validator and `.reduce_dtype()` accept them all. `.apply_reduce()` only executes sum, mean, min, max, median and count. The other six build and plan without complaint, then abort mid-execution with an internal-sounding message. `quantile` also has no argument for the probability, so it cannot be implemented as the API stands. Freezing this vocabulary in v0.1.0 commits to ops that do not exist.

**Evidence.** Checked: `collect(reduce_over(st, op, 't'))` for op in sd, prod, quantile, any each fails with 'reduction op not executable: <op>'. `.reduce_ops` in R/node.R:15-28 lists all 12, and the reduce_over docs (R/lazy_raster.R:874-876) advertise them.

**Suggested fix.** Implement the missing ops in `.apply_reduce()` and the g_* vocabulary, or trim `.reduce_ops` and the docs to the executable set. Validate `op` in `reduce_over()` so an unsupported op fails at construction with a clear message. Drop `quantile` or add a `probs` argument.

**Verifier.** .reduce_ops (R/node.R:15-28) lists 12 ops, but .apply_reduce (R/passes.R:41-51) runs only a subset. Reproduced: collect(reduce_over(st, op, 't')) for sd, prod and any each aborts with 'reduction op not executable'. The documented vocabulary would be costly to narrow after release.

### 13. Integer sources without nodata compute focal edges with 0 instead of NaN
`R/ops.R:99` · kernels · bug

**Problem.** g_upload() replaces NaN with 0 whenever the target dtype is an integer. lazy_source() only retypes an integer source to f32 when nodata or scale is set (lazy_raster.R:146-150). So an Int16/UInt8 raster with no nodata (DEM, land-cover class map) keeps its integer dtype. The NaN halo ring beyond the raster edge then reaches the focal kernel as 0. Cells whose window crosses the edge come out finite, although the focal()/focal_kernel() docs promise 'Cells beyond the raster edge are NaN'. .exec_mask_edge only re-NaNs the export pad margin, not core cells whose window spilled past the edge, so the comment's claim that 'no downstream value depends on it' is false. Results depend silently on the source's storage dtype, and lazy_value_and_grad inherits the same values.

**Evidence.** 6x5 raster of constant 10, focal_kernel(a, matrix(1,3,3)) then reduce_over(..., 'mean', c('x','y')). Float32 file: 90 (12 interior cells). Identical Int16 file: 69.33, and reduce_over(..., 'count') gives 30 instead of 12. sum(collect(fk), na.rm=TRUE) = 2080, so the edge cells are finite.

**Suggested fix.** Do not zero-fill padded halos. Retype integer sources to f32 at upload whenever the consuming stage has a halo (or whenever the chunk contains NaN), and keep zero-fill only for QA/bitwise consumers with halo 0. Add a focal-on-integer-source edge test.

**Verifier.** Reproduced it. On a 6x5 constant-10 Int16 raster with no nodata, focal_kernel gives finite edge cells (40/60) and count 30. The same data as Float32 gives NaN edges. lazy_source only retypes to f32 when nodata or scale is set (lazy_raster.R:146-150). g_upload zero-fills NaN for integer dtypes (ops.R:99-101), so the halo becomes 0, and the gradient path uploads at meta$dtype too. The ops.R comment that 'no downstream value depends on it' is false for core cells next to the raster edge.

### 14. Nine exported names collide with terra/raster generics, and with both loaded the calls fail in both directions
`R/grid.R:383` · package-docs · api

**Problem.** garry exports S7 generics res, xmin, xmax, ymin and ymax (grid.R:363-383), plus mask, align, focal and draw. These all clash with terra's S4 generics, and focal/mask/res/x*/y* also clash with raster's. collect clashes with dplyr::collect. With library(garry) then library(terra), res(grid) fails. With library(terra) then garry, terra's own res()/xmin() on a SpatRaster fails. The README and vignettes promote as_terra() for handing results to terra, so loading both is the expected workflow. Renaming after v0.1.0 is a breaking change.

**Evidence.** terra after garry: res(grid_spec(...)) gives "unable to find an inherited method for function 'res' for signature x = garry::GridSpec". garry after terra: xmin(terra::rast()) gives "Can't find method for xmin(S4<SpatRaster>)". Name intersections: terra: align draw focal mask res xmax xmin ymax ymin; raster: focal mask res xmax xmin ymax ymin; dplyr: collect.

**Suggested fix.** Decide this before release. Option 1: register garry methods on terra's existing S4 generics (S7::method(terra::res, GridSpec) via S4 registration) so the names cooperate. Option 2: rename to non-colliding names (e.g. grid_res(), grid_xmin()). Also consider making collect an S3 generic compatible with dplyr's, or giving it a distinct name.

**Verifier.** R/grid.R:363-383 exports S7 generics xmin/ymin/xmax/ymax/res; NAMESPACE also exports align, collect, draw, focal and mask as plain functions or generics. These mask terra's S4 generics, and there is no S4 method registration bridging the two. Loading both with as_terra() is the expected workflow, so this is a real API collision that is costly to rename after release.

### 15. reduce_over() documents and accepts prod/quantile/sd/var/any/all, but none of them can execute
`R/lazy_raster.R:874` · package-docs · bug

**Problem.** The @param op docs list 12 reduction names. .reduce_ops (R/node.R:13) accepts all 12 when the graph is built, but .apply_reduce (R/passes.R:42) only implements sum/mean/min/max/median/count. A user writes reduce_over(x, "sd", "t"), builds a whole pipeline, and only gets an error at collect(). Over spatial dims the D12 error message (R/passes.R:943) says "median/quantile remain available over t/band", but quantile is not available over t either. "quantile" also has no probs argument at all.

**Evidence.** Tested with a 3-slice lazy_stack over "t" and collect(distributed = FALSE). prod, sd, var, quantile, any and all each fail with "reduction op not executable: <op>"; median returns 2. Over c("x","y") they fail with "op ... cannot be distributed over spatial chunks".

**Suggested fix.** Before release, either implement these ops in .apply_reduce and the decomposition tables, or remove them from .reduce_ops and the docs. Then validate op in reduce_over() with rlang::arg_match so a bad op fails at build time. Fix the D12 message at passes.R:943 and add a test that every documented op runs through collect().

**Verifier.** I confirmed this in the code. .reduce_ops (R/node.R:15-28) lists 12 ops and the reduce_over docs (R/lazy_raster.R:874-876) advertise all of them. .apply_reduce (R/passes.R:42-56) implements only sum/mean/min/max/median/count; any other op hits 'reduction op not executable'. The D12 message at R/passes.R:943 says quantile remains available, which is false. No probs argument exists.

### 16. A dead compute daemon makes every later collect() hang forever
`R/pools.R:649` · scheduler-pools · bug

**Problem.** Each compute profile is a single daemon with dispatcher = FALSE. When that daemon dies (OOM kill, segfault), the in-flight task resolves to errorValue 19 and the run aborts, which is fine. The profile name stays in .garry_state$comp_profiles with 0 connections, though. garry_daemons_set() only checks .comp_n() > 0 summed over all profiles, so it still returns TRUE and collect() takes the distributed path. The next execute_plan_mirai() run-start .pool_broadcast (scheduler.R:279) calls everywhere() on the dead profile and then blocks in m[] forever. If it got past that, pick_comp_prof would route tasks to the dead profile, where they never resolve and the drain loop spins with no timeout. garry_pool_hygiene() hangs the same way. This is exactly the failure mode the memory budgeting exists to survive, and recovering requires the user to know to re-run garry_daemons().

**Evidence.** I verified this with mirai 2.7.2: after daemons(1, dispatcher = FALSE, .compute = 't'), a task that quits the daemon resolves to 'errorValue 19 | Connection reset'. status()$connections is then 0, and a later mirai(1+1, .compute = 't') is still unresolved after 5 s; everywhere() returns an unresolved map. garry_daemons_set() <- .gd_n_compute('garry_read') > 0L && .comp_n() > 0L; .pool_broadcast does lapply(h, function(m) m[]) with no timeout.

**Suggested fix.** At run start (and in garry_daemons_set / .comp_profiles), drop or error on profiles whose .gd_n_compute(p) == 0, e.g. abort with 'compute daemon N is gone; call garry_daemons() to restart'. Alternatively, respawn width-1 profiles that have lost their daemon. Add a timeout to the run-start broadcast and the ABI check.

**Verifier.** I reproduced this with mirai 2.7.2. After a dispatcher=FALSE daemon dies, status()$connections is 0 and everywhere() on that profile stays unresolved. garry_daemons_set() (pools.R:649) sums connections over all comp profiles, so one dead profile out of several still returns TRUE. .pool_broadcast (pools.R:236) waits on m[] with no timeout. No health check exists anywhere else: abi_ok is cached per pool generation, and .comp_profiles never filters out dead profiles.

### 17. Coarse preview re-plan drops SourceNode scale/offset (and resampling), so previews show unscaled values
`R/preview.R:425` · stac-views · bug

**Problem.** .coarsen_node() rebuilds each SourceNode from path, band, nodata, block_dim and open_options only. scale, offset, resampling, name and role fall back to their defaults. Every STAC lazy_dataset source has RESX in its open options, so the coarse path runs for all of them. A dataset built with scale = TRUE (HLS, Landsat C2 L2 with offset -0.2) is therefore previewed in raw DN: the legend is wrong, and so is any derived band or map threshold that depends on scaled reflectance (for example NDVI with a non-zero offset, or `x > 0.3` masks). The plot looks plausible but does not match what collect() returns.

**Evidence.** a <- lazy_source(f, scale = 1e-4, offset = -0.2) gives the node scale 1e-04 and offset -0.2. After .coarsen_node(ng, n, integer(0), .coarsen_grid(n@grid, 2)), the new node has scale numeric(0) and offset numeric(0). Resampling is also reset to "near".

**Suggested fix.** Copy every SourceNode property (scale, offset, resampling, name, role) into the coarse node, for example via S7::props(n) with only grid/open_options overridden. Do the same for the role on Map nodes. Add a test that a coarse preview of a scaled source matches a decimated full collect.

**Verifier.** .coarsen_node (preview.R:425-436) passes only path/band/nodata/block_dim/open_options, so scale, offset, resampling and name fall back to their defaults (node.R:105-114). Every grid-pinned GTI source carries RESX (gdal_adapter.R:1809), so all STAC datasets built with scale=TRUE are previewed in raw DN.

### 18. preview(<file>, bands = ...) indexes the re-read bands with the original band numbers: crash or swapped RGB channels
`R/preview.R:602` · stac-views · bug

**Problem.** .pv_read_path() reads only the requested bands into a compact array, so position i holds band bands[i]. preview() replaces `bands` with the compacted positions (rd$bands) only when the user passed bands = NULL. With explicit bands, .plot_array() then indexes the compact array with the original band numbers. Any band number above 3 fails with 'subscript out of bounds'. A permutation within 1:3 renders the wrong band in each channel: bands = c(3,2,1) puts band 1 in red, the opposite of the request.

**Evidence.** On a 4-band file: .pv_read_path(f, c(4,3,2), 100)$arr[1,1,] gives 40 30 20 (compact). preview(f, bands = c(4,3,2)) fails with "subscript out of bounds", and preview(f, bands = c(3,2,1)) renders silently with the channels reversed. Code: `if (is.null(bands)) bands <- rd$bands` (line 602).

**Suggested fix.** After .pv_read_path, always set bands <- rd$bands (seq_along of the bands read). Add a test that previews a file with bands = c(3,2,1) and with band numbers above 3.

**Verifier.** Reproduced on a 4-band file. .pv_read_path(f, c(3,2,1)) returns the compact values 30 20 10, and preview(f, bands=c(4,3,2)) errors with 'subscript out of bounds' because preview.R:602 replaces bands only when it is NULL.

### 19. stac_query() end_date is effectively exclusive: acquisitions on the end date are dropped
`R/stac.R:53` · stac-views · bug

**Problem.** start_date and end_date both go through as.POSIXct(..., tz = "UTC") and are formatted as midnight. A date-only end_date such as "2023-12-31", the form used in the README and every vignette, becomes "2023-12-31T00:00:00Z", so everything acquired later on 31 December is outside the search window. The result is silently missing the last day of every query.

**Evidence.** Rscript: format(as.POSIXct("2023-12-31", tz="UTC"), "%Y-%m-%dT%H:%M:%SZ") gives "2023-12-31T00:00:00Z". vignettes/hls-harmonized-pca.Rmd calls stac_query(..., end_date = "2023-12-31") and README.md uses end_date = "2023-03-31".

**Suggested fix.** When end_date has no time component (a Date, or a string matching ^\d{4}-\d{2}-\d{2}$), format it as T23:59:59Z, or use an open interval to the next day. Document that the bounds are inclusive and add a test on the formatted datetime string.

**Verifier.** stac.R:53-56 formats both dates as midnight UTC. A date-only end_date (the form the README and vignettes use) yields 'YYYY-MM-DDT00:00:00Z', so the rest of the end day is silently excluded.

### 20. ds[[name]] <- value stores a (t,y,x) stack as one layer, breaking multi-slice datasets
`R/dataset.R:559` · user-api · bug

**Problem.** On a multi-slice dataset, ds[["B04"]] returns a lazy_stack along t, so the documented idiom ds[["ndvi"]] <- (nir - red)/(nir + red) assigns a single 3D layer. The other bands still hold N per-slice 2D layers. The assign checks only .spatial_equal, so it accepts this. Afterwards reduce_over(ds, op, "t") fails ('cannot stack along existing dim t'), mask() fails ('has 1 slices but mask band has 2'), and stack_bands refuses.

**Evidence.** d3 with two slices per band: d3[["c"]] <- d3[["a"]] - d3[["b"]] gives lengths a=2 b=2 c=1 with c dims x y t; reduce_over(d3, "mean", "t") errors "cannot stack along existing dim `t`" (verified).

**Suggested fix.** When value carries a t dim matching the dataset's slice count, split it back into per-slice layers named by the t labels (as .lr_as_dataset does). Otherwise reject values that carry non-spatial dims, with a clear message.

**Verifier.** Reproduced: after d3[['c']] <- d3[['a']] - d3[['b']] the band lengths are a=2 b=2 c=1, and reduce_over(d3,'mean','t') errors 'cannot stack along existing dim t'. The assign method only checks .spatial_equal, and the ds[[...]] <- idiom is the documented usage.

### 21. extract_points ignores the source band index, band subsetting, nodata and scale of a materialised cube
`R/extract_points.R:146` · user-api · bug

**Problem.** .px_local_sources keeps only n@path and drops n@band, n@nodata, n@scale and n@offset. When every band reads one multi-band file (materialise() output, or the file form of lazy_dataset), it returns the single path, and pixel_extract samples ALL file bands in file order. So lazy_source(f, band = 3), cube[c("B08","B04")], or lazy_dataset(f, bands = 2L) all return every band. Column names are the file's, not the dataset's. User-supplied nodata is not applied and scale = TRUE sources return raw DN. The `bands` argument is interpreted as file band indices, not dataset band names.

**Evidence.** extract_points(lazy_source(mb.tif, band = 3), pts), extract_points(d[c("b3","b1")], pts) and extract_points(lazy_dataset(mb.tif, bands = 2L), pts) all return mb_b1 mb_b2 mb_b3 = 10 20 30 (verified). Tests only cover bands = 1L on a single-band file.

**Suggested fix.** Return (path, band) pairs from .px_local_sources. Pass the band indices to pixel_extract in dataset order, name the columns by dataset band, and apply the node's nodata->NaN and scale/offset (or refuse sources with nodata/scale overrides).

**Verifier.** .px_local_sources (extract_points.R:136-159) keeps only n@path. Reproduced: extract_points(lazy_source(mb, band=3)) and extract_points(lazy_dataset(mb, bands=2L)) both return all three file bands (10 20 30).

### 22. sum/prod reductions keep small integer dtypes; written output clamps or overflows
`R/generics.R:161` · user-api · bug

**Problem.** .reduce_dtype returns the input dtype for sum and prod. Summing a u8 class or mask band over t or x/y declares u8, and summing i16 over many slices declares i16. The in-memory collect() result is correct (computed wider), but write_tif() writes the declared dtype, so values saturate at the type maximum. numpy and xarray accumulate sums of small ints in int64/float.

**Evidence.** reduce_over(lazy_stack(list(a=xu,b=xu,c=xu)), "sum", "t") over a Byte raster of 200s: grid dtype u8; collect() gives 600; write_tif writes Byte with all 255 (verified). Over x,y the collect gives 3200 while the dtype is u8.

**Suggested fix.** Widen sum/prod for integer inputs (i64/f64, or at least i32/f32), matching what the kernel actually produces, so the declared dtype matches the computed values on every sink.

**Verifier.** .reduce_dtype (generics.R:153-164) keeps the input dtype for sum and prod. Reproduced: summing three u8 rasters of 200 over t gives dtype u8, collect returns 600, and write_tif writes Byte 255. The result is wrong only on write, so high rather than critical.

### 23. Scalar arithmetic on integer rasters keeps the integer dtype; write_tif truncates or rounds the float result
`R/lazy_raster.R:471` · user-api · bug

**Problem.** .lazy_scalar_op sets the output dtype to dtype_promote(lr dtype, lr dtype), so a non-integer scalar never widens an integer raster. x * 0.5, x * 0.0000275 - 0.2 (Landsat DN scaling), x + 1.5 on an i16/u16/u8 source without file nodata all declare the integer source dtype. The in-memory collect() returns the true float values, but the gis attr says Int16, and write_tif()/materialise() write an integer file with the values rounded. Scaling DN to reflectance written to disk becomes all zeros. %% has the same weak-scalar rule (line 565). In R, int * 0.5 gives a double.

**Evidence.** lazy_source(i16.tif) * 0.5 has grid dtype "i16". collect() gives 0.5 1 1.5 ... but write_tif(x * 0.5, out) writes an Int16 band with values 1 1 2 2 3 3 ... (verified).

**Suggested fix.** Promote to float when a scalar is non-integral (or always when the scalar is double and the raster is integer), and keep integer dtype only for integer-valued scalars. Add a test that write_tif of int * 0.5 is float.

**Verifier.** Reproduced: (x*0.5) on an Int16 source with no nodata has dtype i16, and write_tif writes Int16 with values 1 1 2 2 3 3. The weak-scalar rule at lazy_raster.R:460-474 never looks at whether the scalar is fractional. Downgraded from critical because an integer source with file nodata or scale=TRUE is already promoted to float, so this only hits integer sources with no nodata.

### 24. Math group on a LazyDataset keeps the integer band dtype (sqrt/log written truncated)
`R/lazy_raster.R:606` · user-api · bug

**Problem.** .lazy_math computes the float output dtype only when x is a LazyRaster. For a LazyDataset (.lazy_math_dataset, dataset.R:1327) dtype stays NULL, so .ds_map -> lazy_map declares the promoted input dtype. sqrt(ds), log(ds), exp(ds) on integer bands therefore declare i16/u16, and write_tif rounds the result to integers.

**Evidence.** sqrt(as_dataset(list(a = lazy_source(i16.tif))))@bands$a[[1]]@grid@dtype is "i16"; write_tif of it writes Int16 with values 1 1 2 2 2 2 3 3 ... (verified). sqrt(x) on the bare LazyRaster correctly gives f32.

**Suggested fix.** Compute the dtype per band inside the dataset path. For example, have .lazy_math map each layer through .lazy_math itself instead of calling lazy_map(x, dtype = NULL).

**Verifier.** In .lazy_math, dtype is only set when x is a LazyRaster. Reproduced: sqrt(as_dataset(list(a=i16 source)))@bands$a[[1]]@grid@dtype is i16, so write_tif rounds the result.

## Medium (46)

### 25. band_names argument is silently ignored for LazyDataset and LazyDatasetGroups, and its doc points at a collect() parameter that does not exist
`R/collect.R:58` · executor-daemons · api

**Problem.** For a LazyDataset, .collect_impl unconditionally replaces band_names with names(x@bands), so write_tif(ds, band_names = ...) has no effect. For LazyDatasetGroups, band_names is never passed on to .collect_groups. write_tif() documents band_names as 'As in [collect()]', but collect() has no band_names parameter, so the argument has no real documentation.

**Evidence.** write_tif(as_dataset(list(red=list(x), nir=list(x*2))), 'bn.tif', band_names=c('A','B')) wrote band descriptions 'red','nir'. collect's signature is function(x, plan_only = FALSE, distributed = garry_daemons_set()).

**Suggested fix.** Use `band_names %||% names(x@bands)` and forward band_names to .collect_groups. Document the argument in write_tif() directly, including its precedence over dataset and stack labels.

**Verifier.** collect.R:57-58 overwrites band_names with names(x@bands) for LazyDataset. .collect_groups takes no band_names parameter, and the multi-group route builds its own names (collect.R:263-264). write_tif documents band_names as 'As in [collect()]', but collect() has no such parameter.

### 26. Masked full-grid band reduce overflows an integer byte count for large time cubes
`R/daemon.R:956` · executor-daemons · bug

**Problem.** In the non-strip path (taken when the compute pool has one daemon, since gd_strips defaults to the pool width), the whole mask cube is read with n = n * k$ny * nx * 4L. n, ny and nx are all integers (grid dims), so the product overflows to NA once n*ny*nx exceeds ~536.9 M pixels, and readBin() then errors with 'invalid n'. One HLS MGRS tile (3660 x 3660) crosses that at about 41 time slices, which is a normal annual composite. The strip path computes per-slice counts and is not affected.

**Evidence.** `readBin(k$mask_bin, "raw", n = n * k$ny * nx * 4L)` with n <- length(job$band_bins). grid@dims are integer, e.g. gis$dim printed as int.

**Suggested fix.** Do the arithmetic in double (as.numeric(n) * k$ny * nx * 4), or read the mask per slice as the strip path does.

**Verifier.** daemon.R:956: n (length()), k$ny and nx (integer grid dims via composite_direct.R:415-416) multiply with 4L in integer arithmetic. For 3660x3660 this overflows to NA at n>=41, and readBin errors. The path is taken when ns=1 (gd_strips<1 and a compute pool width of 1, composite_direct.R:813-817), where h==k$ny makes strip FALSE. The strip path uses per-slice reads with as.numeric offsets.

### 27. Multi-export write paths are not validated: an unnamed vector or a single file path gives 'subscript out of bounds'
`R/executor.R:919` · executor-daemons · api

**Problem.** For a named-list x, the documented path forms are an existing directory or a character vector named by sink. Anything else reaches path[[nm]] deep in the sink tail (the scheduler has the same code at scheduler.R:1499-1503) and fails with a bare base-R 'subscript out of bounds'. That covers an unnamed c('a.tif','b.tif'), a single 'out.tif', and a directory that does not exist yet. write_tif() validates only that path is non-NA character. A LazyRaster given a length-2 path also reaches gdal_create_output with a vector.

**Evidence.** write_tif(list(a=x, b=x+1), 'out.tif') errors with 'subscript out of bounds'. write_tif(list(a=x, b=x+1), c('a.tif','b.tif')) errors the same way.

**Suggested fix.** In write_tif()/materialise()/.collect_impl, check up front that a multi-sink path is either an existing directory or a vector whose names match names(x) exactly, and that a single-sink path has length 1. Abort with a cli message naming the accepted forms.

**Verifier.** executor.R:919-923: unless path is a single existing directory, the code does path[[nm]]. For an unnamed c('a.tif','b.tif'), a single 'out.tif' or a non-existent directory, this is a base 'subscript out of bounds' after execution. write_tif validates only that path is non-NA character.

### 28. FILTER open option is parsed by regex as a slice label; any other GTI filter breaks the default route
`R/composite_direct.R:426` · gdal-io · bug

**Problem.** .gd_build_jobs extracts the last single-quoted literal of the FILTER and matches it against entries$slice. Any filter not of the form "slice = 'x'" breaks: datetime ranges, other columns, compound filters, or an index built with gti_index_create() (exported, and it writes the .meta.rds that makes the source eligible) without a `slice` column. These select zero items, so every warp fails with 'no items for this slice' and collect() aborts. Under read_fail = 'nodata' it returns an all-NaN composite. If the literal happens to equal a slice label, the wrong items are selected. The scheduler route evaluates the real OGR filter and succeeds.

**Evidence.** Probe: lazy_source GTI slices with filter "datetime < '2020-01-15'". The oracle returns 4; distributed collect on route composite_direct aborts with 'gdal-direct: 2/2 source warps failed (e.g. no items for this slice)'.

**Suggested fix.** Accept only an exact `^slice = '([^']*)'$` filter (and a `slice` column) in .cd_spec/.gd_spec, and return NULL otherwise so the plan falls to the scheduler. Alternatively, evaluate the filter against the index with OGR.

**Verifier.** L426-431 takes the last single-quoted literal of any FILTER and matches it against e$slice. Eligibility needs only the .meta.rds sidecar, which gti_index_create writes for any index (L1659-1662), and gti_open_options(filter=) accepts arbitrary OGR SQL. The scheduler explicitly gates its fetch split to garry's "slice = '...'" form (scheduler.R:371, 452); composite_direct has no such gate. Any other filter selects the wrong items or none.

### 29. Warp-on-read routes ignore the GTI SORT_FIELD/SORT_FIELD_ASC and always draw the latest datetime on top
`R/composite_direct.R:433` · gdal-io · bug

**Problem.** .gd_build_jobs() keeps only locs and datetime per slice. .cd_fetch_warp then warps j$locs[order(j$dt)], so the last datetime wins regardless of the source's open options. lazy_dataset()/lazy_stac_stack() expose `sort_field`, and gti_open_options() exposes sort_field/sort_asc. The scheduler/single route honours them through the GTI driver, but the default distributed routes (composite_direct and gd_reduce) silently do not. Overlapping items within a slice then resolve differently depending on route.

**Evidence.** Probe: a slice with two full-cover tiles (values 1 and 2, prio = 2 and 1) and sort_field = 'prio'. The oracle (GTI) gives mean 3; collect(distributed = TRUE) on route composite_direct gives 4.

**Suggested fix.** Parse SORT_FIELD/SORT_FIELD_ASC from n@open_options in .gd_build_jobs and order the locations by that entries column, or decline the fast path (return NULL from .cd_spec/.gd_spec) when the sort field is anything other than ascending datetime.

**Verifier.** .gd_build_jobs (L415-446) keeps only locs and datetime, and .cd_fetch_warp (daemon.R:1024) warps j$locs[order(j$dt)], ignoring SORT_FIELD/SORT_FIELD_ASC in n@open_options. The default sort_field = 'datetime' (with ascending order) matches, so only a non-default sort_field or sort_asc diverges from the scheduler/GTI route. Medium rather than high.

### 30. Warp-on-read ignores SourceNode@band, so multi-band GTI items fail (or become all-NaN) on the default route
`R/composite_direct.R:452` · gdal-io · bug

**Problem.** The per-source job carries locs/dt/nodata/resampling/bin but not n@band, and .cd_fetch_warp calls gdal_warp_to_buffer without `band`. A GTI source over multi-band tiles read with lazy_source(..., band = k) is accepted by .cd_spec/.gd_spec, because nothing checks band. gdalwarp then tries to warp every band into the 1-band MEM buffer and fails. Under read_fail = 'nodata' the result is an all-NaN composite. Even with band = 1 on multi-band items this relies on GDAL behaviour rather than an explicit -srcband.

**Evidence.** Probe: 2-band tiles, lazy_source(GTI, band = 2L), mean over t. The oracle returns 15; distributed collect on route composite_direct aborts with 'gdal-direct: 2/2 source warps failed (e.g. warp raster failed)'.

**Suggested fix.** Add band = n@band to each job in .gd_build_jobs and pass it through .cd_fetch_warp to gdal_warp_to_buffer(band =) (the -srcband path already exists).

**Verifier.** The job bundle (L438-446) has no band field, and .cd_fetch_warp calls gdal_warp_to_buffer without band, although that function supports -srcband (L1479-1481) and gdal_warp_window passes it. Neither .cd_spec nor .cd_reduce_spec checks n@band. A GTI over multi-band items read with band = k > 1 is therefore mis-read on the default route.

### 31. Exported gdal_read_window(scale = s) without offset silently returns an empty matrix
`R/gdal_adapter.R:359` · gdal-io · api

**Problem.** The matrix branches of .gdal_finish_vec, .gdal_read_window_bands and .raw_vrt_read compute `v * scale + offset`. With the documented default offset = numeric(0), R gives numeric(0), so a 4x4 read returns a 4x0 matrix with no error. The raw_f32 branch treats a missing offset as 0, so the two output forms disagree. lazy_source fills offset = 0, but gdal_read_window is exported and documents scale/offset as independently length 0 or 1.

**Evidence.** gdal_read_window(p, 1L, 0L, 0L, 4L, 4L, scale = 0.5) gives dim 4 0; the same call with out = 'raw_f32' gives 64 bytes.

**Suggested fix.** Normalise at entry: if (length(scale) == 1L && length(offset) == 0L) offset <- 0. Validate that both are length <= 1.

**Verifier.** .gdal_finish_vec L359-361 computes v*scale+offset; with offset = numeric(0) this gives numeric(0), and matrix(numeric(0), nrow = y_size) is y_size x 0. The raw_f32 C path takes offset separately. gdal_read_window is exported, and its docs describe scale and offset as independently length 0/1.

### 32. Low-level adapter internals are exported as stable public API
`R/gdal_adapter.R:394` · gdal-io · api

**Problem.** gdal_read_window (whose `decim` argument takes the internal .rio_direct_spec() list), gdal_write_window, gdal_create_output (returns a raw gdalraster object the caller must $close()), gdal_warp_vrt (leaves a tempdir VRT per call), gdal_grid_spec and stage_raw_cube are exported without @keywords internal. Releasing them in v0.1.0 freezes GDAL-convention signatures (0-based offsets, row-major payload attributes, raw_f32 gdim/gdt structure) that the D13 quarantine is meant to keep private. Each of the bugs above in these functions then becomes a public contract.

**Evidence.** NAMESPACE: export(gdal_create_output), export(gdal_grid_spec), export(gdal_read_window), export(gdal_warp_vrt), export(gdal_write_window), export(stage_raw_cube); roxygen @param decim refers to [.rio_direct_spec()].

**Suggested fix.** Mark the adapter functions @keywords internal (keeping the export only where daemons need `garry::`), or drop the exports before release and keep stage_raw_cube as the one documented user-facing entry.

**Verifier.** NAMESPACE exports gdal_create_output, gdal_grid_spec, gdal_read_window, gdal_warp_vrt, gdal_write_window and stage_raw_cube, and _pkgdown.yml lists them in the reference. The roxygen for decim points to the internal .rio_direct_spec(). This is a legitimate pre-release API concern, though the export may be deliberate.

### 33. stage_raw_cube drops band scale/offset, uses band 1's nodata/dtype only, and flips south-up sources
`R/gdal_adapter.R:659` · gdal-io · bug

**Problem.** stage_raw_cube reads raw DNs (gdal_read_window with no scale) and writes a VRT without <Scale>/<Offset>. A scaled source (e.g. HLS reflectance, AEF int8 quantized) therefore loses its affine, and re-reading the cube with scale = TRUE yields DNs. It also takes nodata and dtype from band 1 only: a Float64 band after a Float32 band 1 is truncated to f32, and per-band nodata is collapsed. It inherits the south-up flip because gdal_grid_spec normalises the transform but the rows are copied in file order. The output connection is not closed on error (no on.exit).

**Evidence.** L659 meta <- gdal_grid_spec(src) (band 1 only); L679 gdal_read_window(src, b, 0L, y0, nx, rows) with no scale/offset; .raw_bsq_vrt_xml has no Scale/Offset elements; L673 con <- file(bin, 'wb') closed only at L685.

**Suggested fix.** Write per-band <Scale>/<Offset>/<NoDataValue> into the VRT (extend .raw_bsq_vrt_xml), pick f64 if any band is Float64, apply the south-up fix, and close `con` via on.exit.

**Verifier.** stage_raw_cube (L655-700) calls gdal_read_window without scale/offset/nodata and passes no scale to .raw_bsq_vrt_xml. It takes nodata from gdal_grid_spec(src) (band 1) and the dtype from getDataTypeName(1L). It inherits the south-up flip from finding 1, and con <- file(bin,'wb') has no on.exit close. All as described.

### 34. gdal_mosaic_vrt's skipped-source guard counts SourceFilename lines, which multi-band tiles inflate
`R/gdal_adapter.R:1201` · gdal-io · bug

**Problem.** buildVRT writes one <SourceFilename> per band per source, so n_in = files x bands. With multi-band tiles (the file form of lazy_dataset is built for multi-band AEF/ESD files), losing a tile still leaves n_in >= length(files), and the 'took n of m sources' abort never fires. buildVRT skips tiles for reasons .mosaicable does not check: heterogeneous band counts, data types or open failures. The mosaic then silently has a hole where the skipped tile was.

**Evidence.** Probe: three north-up EPSG:3857 tiles with 3, 3 and 2 bands. GDAL warns 'Skipping ...tif', gdal_mosaic_vrt returns the VRT without error, and the VRT has 6 SourceFilename lines for 3 files.

**Suggested fix.** Count distinct SourceFilename values (unique paths) instead of lines, or compare against the set of input paths, and abort when any input path is missing.

**Verifier.** L1201 counts <SourceFilename lines. buildVRT emits one per band per source, so with multi-band tiles a skipped tile still leaves n_in >= length(files). .mosaicable (L1219-1226) checks only north-up orientation and projection, not band count or dtype, so a heterogeneous tile can be skipped silently and leave a hole.

### 35. Exported extension API (fusable, is_barrier, FusedNode) is never consulted by the planner
`R/generics.R:40` · ir-planning · dead-code

**Problem.** `fusable()` and `is_barrier()` are exported and documented as 'the extension API for authors of new node classes'. The planner (`.plan_lazy_impl` Phase A) hardcodes class checks and never calls either, so a new node class's methods have no effect. They also contradict actual behaviour: `is_barrier(ReduceNode)` and `is_barrier(ScanNode)` are TRUE, yet t/band reduces and scans fuse into compute stages. `FusedNode` is exported, but no pass ever constructs one; only draw.R and output_grid/required_halo methods reference it.

**Evidence.** grep shows no call sites of `fusable(` / `is_barrier(` outside R/generics.R; `FusedNode(` is never constructed (R/node.R:380, NAMESPACE exports FusedNode, fusable, is_barrier).

**Suggested fix.** Before the stable release, unexport or remove fusable/is_barrier/FusedNode, or wire the planner to dispatch on them so the documented extension contract holds.

**Verifier.** A grep of R/ finds no call sites for fusable( or is_barrier( outside their definitions in R/generics.R, and no FusedNode( constructor call. All three are exported (NAMESPACE lines 28, 66, 142). is_barrier is TRUE for ReduceNode and ScanNode, which contradicts the planner fusing t/band reduces.

### 36. Exported S7 generics xmin/xmax/ymin/ymax/res mask terra/raster generics
`R/grid.R:363` · ir-planning · api

**Problem.** garry exports new S7 generics named `xmin`, `ymin`, `xmax`, `ymax` and `res` with methods only for GridSpec and LazyRaster. When garry is attached after terra or raster, as is typical in geospatial sessions, calls like `res(spat_raster)` dispatch to garry's generic and error with no method found. This is hard to change once v0.1.0 ships.

**Evidence.** `xmin <- S7::new_generic("xmin", "x")` and siblings (R/grid.R:363-386), all `@export`ed. S7 generics have no fallback to other packages' generics.

**Suggested fix.** Use non-clashing names such as `grid_xmin()` / `grid_res()`, or register S7 methods on terra's existing generics via S7::method(terra::xmin, ...) behind Suggests, rather than defining new generics with the same names.

**Verifier.** R/grid.R:363-386 defines and exports S7 generics xmin, ymin, xmax, ymax and res (NAMESPACE exports them). Verified that res() on a foreign S3 object raises S7_error_method_not_found, so attaching garry after terra or raster masks their accessors for SpatRaster and similar objects.

### 37. align() accepts any resampling string; typos surface as a GDAL failure at collect time
`R/lazy_raster.R:1102` · ir-planning · api

**Problem.** `resampling` is stored unvalidated on the WarpNode, and SourceNode@resampling has the same problem. A bad name only fails inside the GDAL warper during execution, after daemons and reads have started, with no hint of which argument was wrong. The WarpNode docs list 'nearest' while SourceNode defaults to GDAL's 'near'; both work, but the accepted vocabulary is undocumented.

**Evidence.** Checked: `collect(align(b1, tg, resampling = 'bogus'))` gives 'GDAL FAILURE 1: Unknown resampling method' / 'warp raster failed (could not create options struct)'.

**Suggested fix.** Validate against the GDAL warp resampling set, including the 'nearest' alias, in align() and lazy_source(), and document the accepted values.

**Verifier.** align() stores resampling without validating it (R/lazy_raster.R:1102-1116). Reproduced: resampling = 'bogus' fails only at collect, with 'GDAL FAILURE 1: Unknown resampling method / warp raster failed (could not create options struct)'. The WarpNode doc lists 'nearest' while SourceNode defaults to 'near'.

### 38. focal() does not validate radius; negative/NA/vector radius fails later with an internal ChunkGrid error
`R/node.R:185` · ir-planning · api

**Problem.** The FocalNode validator checks only weights length. `focal()` passes `as.integer(radius)` straight through, so -1, NA, 1.7 (silently truncated to 1) or c(1,2) are accepted. A negative radius flows into `required_halo` and `.stage_halo`, and the user later sees a ChunkGrid validator message about `halo` that does not mention focal or radius.

**Evidence.** Checked: `focal(x, fn, radius = -1)` returns a LazyRaster. `collect()` on it fails with '<garry::ChunkGrid> object is invalid: - `halo` must be a single non-negative integer'.

**Suggested fix.** Validate in the FocalNode validator and in focal(): `length(radius) == 1`, not NA, a whole number, and `>= 0`.

**Verifier.** The FocalNode validator (R/node.R:185-191) checks only the length of weights, and focal() does not validate radius. Reproduced: focal(x, fn, radius = -1) builds a LazyRaster, and collect fails with the ChunkGrid 'halo must be a single non-negative integer' message, which never mentions radius.

### 39. In-place band-stack collapse makes planning history-dependent (warp of a stack becomes a raw GDAL failure)
`R/passes.R:630` · ir-planning · bug

**Problem.** `.collapse_band_stacks()` rewrites the user's shared graph in place, turning a StackNode into a multi-band SourceNode. Its WarpNode-consumer guard only sees consumers reachable from the current sinks. After any collect of an expression using the stack, a later `align(stack, ...)` passes Phase A's 'warp parent must be a SourceNode' check, because the parent is now a SourceNode. It then reaches the GDAL warper with a band vector and fails with an opaque error. The same expression gives a clear planner error before the first collect and a GDAL crash after it. The rewrite is described as 'semantics-preserving and idempotent', but it changes which code path later plans take.

**Evidence.** Checked: `s <- lazy_stack(list(b1,b2), along='band')`. First `plan_lazy(align(s, tg))` aborts with 'warping a computed raster is not supported in v1'. After `collect(s + 1)`, `collect(align(s, tg))` fails with 'GDAL FAILURE 1: Zero positional arguments expected / warp raster failed (could not create options struct)'.

**Suggested fix.** Do the collapse on a planning copy of the node table, or keep the original StackNode and record the collapse in plan-local state. At minimum, make Phase A's warp check reject SourceNodes with `length(@band) > 1` or a non-empty `@collapsed` using the same planner error.

**Verifier.** Reproduced. Before any collect, plan_lazy(align(stack, tg)) aborts with the clear 'warping a computed raster' error. After collect(s + 1), the graph shows the StackNode rewritten in place as a SourceNode, and collect(align(s, tg)) fails in GDAL with 'Zero positional arguments expected'. The rewrite really does make planning depend on history. Downgraded: both paths reject an unsupported op, so only the error quality differs.

### 40. Plan-wide chunk snapping overflows integer LCM and crashes with mixed native block widths
`R/passes.R:1583` · ir-planning · bug

**Problem.** `.lcm2()` returns `as.integer(a / gcd * b)`, and `.plan_chunk_dim()` reduces it over every stage's native block before applying the 'incommensurable -> no snap' fallback. Full-width strip GeoTIFFs report block = (width, rows), and warp stages inherit their source's block, so aligning a few strip sources of different widths overflows int32. The result is NA, and the next `.gcd2` call aborts with 'missing value where TRUE/FALSE needed' instead of falling back to block 1.

**Evidence.** Checked: `Reduce(garry:::.lcm2, c(1L, 10980L, 7681L, 8821L, 5490L), 1L)` errors with 'Error in if (b == 0L) ...: missing value where TRUE/FALSE needed' after an 'NAs introduced by coercion to integer range' warning.

**Suggested fix.** Compute the LCM in double precision and stop early once it exceeds `2 * side`, returning 1L. Separately, warp stages should not inherit the source's native block, since it lives on a different grid.

**Verifier.** .lcm2 (R/passes.R:1583) coerces with as.integer, and .plan_chunk_dim (line 1633) reduces it over every stage block before the 'l > 2*side' fallback. Warp stages inherit their source's block_dim (.stage_block, lines 1400-1411). Reproduced the NA and the 'missing value where TRUE/FALSE needed' abort. It needs three or more mutually awkward strip widths in one plan: plausible, but an edge case.

### 41. Gradient tape ignores NaN produced inside the pipeline (value NaN, grad silently wrong)
`R/gradient.R:74` · kernels · bug

**Problem.** The mask-multiply rewrite zero-substitutes nodata only at the stage inputs (lines 46-47). For a MapNode it carries the mask forward as the product of the parent masks (line 74) and never removes NaN that the node's own fn produces, for example g_ifelse(v > t, NaN, v), mask()-style gating, or log of a negative value. The tail then computes g_sum(out * mask) with NaN * 1, so the loss value is NaN. collect() of the same loss skips those cells through nan_rm. The gradient stays finite, because select has a zero cotangent, but C (sum of mask) still counts the NaN cells, so the mean gradient is divided by the wrong count. This contradicts the documented guarantees that 'gradients are never poisoned by NaN' and that forward values agree with nan_rm semantics.

**Evidence.** Float32 raster 1:30. fk <- focal_kernel(a, matrix(1,3,3)); loss <- reduce_over(lazy_map(fk, fn = function(v) g_ifelse(v > 150, NaN, v)), 'mean', c('x','y')). collect(loss) = 106.71; lazy_value_and_grad(loss, fk)$value = NaN, with finite grad entries 2.83..11.0.

**Suggested fix.** After each Map/Focal node, fold the node's own NaN into the mask and zero-substitute: m <- m * g_cast(!g_is_nodata(v), 'f32'); v <- g_ifelse(g_is_nodata(v), 0, v). Add an FD test with a NaN-producing map.

**Verifier.** In gradient.R:74 the MapNode mask is Reduce('*', parent masks) and never ANDs in !is_nodata(v). The tail at line 111 computes g_sum(out * mask), so NaN produced inside the stage makes the loss value NaN, and c = sum(mask) counts those cells. This contradicts the header's nan_rm agreement claim (lines 19-21). It needs a map that emits NaN, which is plausible (masking), so medium rather than high.

### 42. Gradient source reads ignore the source's resampling and GTI wrapping
`R/gradient.R:262` · kernels · bug

**Problem.** lazy_value_and_grad reads chunks with .exec_read_padded(meta$node@path, ...) and passes neither resampling nor the .gti_resampled_path() wrapper. The executor's source_read stage passes both (executor.R:1039-1063). For a multi-path mosaic or a GTI source declared with resampling = 'bilinear' (or any non-near method), the gradient path reads with nearest neighbour. Its value and gradient then disagree with collect() of the same loss. .grad_validate only rejects explicit 'warp' stages, so these sources are accepted. I confirmed this by reading the code; I did not run it.

**Evidence.** gradient.R:262-271 calls .exec_read_padded(meta$node@path, meta$node@band, meta$node@nodata, meta$chunks, it[j, ], open_options=, scale=, offset=) with no resampling argument, so it defaults to 'near'. executor.R:1039 uses rpath <- .gti_resampled_path(node@path, node@resampling) and resampling = rresamp.

**Suggested fix.** Share one helper with the executor that builds the read arguments (path wrapping, resampling, decim) for a SourceNode, and call it from both places.

**Verifier.** gradient.R:262-271 calls .exec_read_padded with no resampling argument (default 'near') and passes the raw node@path, not .gti_resampled_path. For multi-path sources, .exec_read_padded calls gdal_warp_window(resampling = resampling) (executor.R:162-176), so a mosaic declared bilinear is read nearest on the gradient path while collect() uses rresamp (executor.R:1039-1063). .grad_validate rejects only 'warp' stages.

### 43. g_ifelse with a traced condition and two scalar branches errors
`R/ops.R:320` · kernels · api

**Problem.** When both yes and no are R scalars, g_ifelse promotes yes via .g_scalar_like(no, yes) while no is still a plain R double. anvl::nv_scalar_like then refuses it. A natural user body such as lazy_map(x, fn = function(v) g_ifelse(v > 0, 1, 0)) therefore works on the oracle path but crashes on every real (traced) execution. g_ifelse is the headline user vocabulary op in the vignettes.

**Evidence.** g_jit(function(x) g_ifelse(g_is_nodata(x), 1, 0))(x) -> "`like` must be an array to take defaults from. Got an R double, which has no data type of its own."

**Suggested fix.** When both branches are scalars, take the dtype from cond's shape with a float default, e.g. yes <- anvl::nv_fill(yes, shape(cond), 'f32'), or promote both against a zeros-like of cond. Add a traced parity test for the scalar/scalar case.

**Verifier.** Reproduced the error exactly: g_jit(function(x) g_ifelse(g_is_nodata(x), 1, 0)) aborts with '`like` must be an array to take defaults from'. At ops.R:320-325, yes is promoted with .g_scalar_like(no, yes) while no is still an R double. The fix is to promote against cond or to use a dtype default.

### 44. Truncated safetensors payloads are silently recycled; OCM loading never verifies weight hashes
`R/safetensors.R:85` · kernels · bug

**Problem.** safetensors_read computes n from data_offsets and calls readBin without checking that it returned n values, or that n equals prod(shape). array(v, rev(shape)) recycles a short vector without a warning, so a truncated file (an interrupted copy into GARRY_OCM_WEIGHTS, a partial Python cache) yields correctly shaped but garbage tensors. ocm_load_weights checks only names and a few shapes, which recycling preserves. It never compares against .ocm_release_hash, and it caches the garbage result as .rds keyed by the bad file's hash. The header comment at ocm_weights.R:10-11 ('a wrong or truncated weight file fails loudly at build') is therefore false.

**Evidence.** Hand-written file declaring a w[2,4] F32 tensor with 8 values but holding only 5 floats: safetensors_read returned a 2x4 matrix [1 2 3 4; 5 1 2 3] with no error or warning.

**Suggested fix.** In safetensors_read, abort when length(v) != n or when n != prod(shape) (scalars excepted), and validate end >= begin. In ocm_load_weights, compare file hashes with .ocm_release_hash and warn or abort on a mismatch for known file names.

**Verifier.** safetensors.R:85-90: readBin's returned length is not checked against n or prod(shape), and array() recycles silently. .st_header does not check the file size against data_offsets. ocm_load_weights hashes the file only to build the cache key and never compares against .ocm_release_hash, which is checked only in ocm_fetch_weights. The ocm_weights.R:10-11 claim that a truncated file 'fails loudly' therefore does not hold for a truncated payload.

### 45. Release metadata still says pre-release and experimental
`DESCRIPTION:3` · package-docs · docs

**Problem.** On the v0.1.0 branch, DESCRIPTION has Version 0.0.0.9000 and its Description starts "Experimental." README.Rmd keeps the experimental lifecycle badge and a WARNING block: "The API changes without deprecation ... nothing here should be treated as stable yet." There is no NEWS.md, although _pkgdown.yml's navbar includes `news`. This contradicts the purpose of a first more-stable release.

**Evidence.** DESCRIPTION:3 Version: 0.0.0.9000; DESCRIPTION:6 "Description: Experimental."; README.Rmd badge lifecycle-experimental and the WARNING block; `ls NEWS*` finds no file.

**Suggested fix.** Bump to 0.1.0, reword the Description and the README warning (e.g. a maturing badge plus a statement of the stability policy), and add NEWS.md with a 0.1.0 section.

**Verifier.** DESCRIPTION has Version 0.0.0.9000 and 'Description: Experimental.'. README.Rmd:20 has the experimental badge and :26-29 the 'nothing ... stable' WARNING. No NEWS file exists, yet _pkgdown.yml:15 lists news in the navbar.

### 46. Lazy objects have no names()/length()/dim()/$ support, so the docs reach into @ slots
`R/dataset.R:530` · package-docs · api

**Problem.** LazyDataset defines only [[, [ and [[<-. On a dataset, names(ds) returns NULL and length(ds) returns 1. ds$B04 and ds$c <- x fail with S7's "Can't get S7 properties with `$`". dim() and names() on a LazyRaster return NULL. There is no accessor for time labels or grid dims, so the shipped vignettes use internal slots: ndvi@grid@labels$t (time-series), ds[["B04"]]@grid@labels$t (omnicloudmask), target@dims (stac-composite) and grid@crs (aef). Once released, these slot layouts become de facto public API.

**Evidence.** as_dataset(list(a = r, b = r * 2)): names(d) gives NULL, length(d) gives 1, d$a gives "Can't get S7 properties with `$`. Did you mean `d@a`?". vignettes/time-series.Rmd.orig: dates <- as.Date(ndvi@grid@labels$t).

**Suggested fix.** Add names()/length() methods for LazyDataset and $/$<- forwarding to [[/[[<-. Add dim() for LazyRaster/GridSpec and a time-label accessor (e.g. time_labels()). Then rewrite the vignettes to use these instead of @.

**Verifier.** R/dataset.R defines only [[, [ (S7 methods, lines 530/539) and [[<- (S3). There are no names, length, dim or $ methods anywhere in R/. The vignettes do reach into slots: time-series.Rmd.orig:78 (@grid@labels$t), omnicloudmask.Rmd.orig:109, stac-composite.Rmd.orig:61 (target@dims) and aef-embeddings.Rmd.orig:99 (grid@crs).

### 47. ocm example calls reduce_over() with the arguments swapped and a nonexistent axis
`R/ocm.R:92` · package-docs · docs

**Problem.** The @examples for ocm_model/ocm_mask/ocm_predict contain `ds |> reduce_over("time", "median")`. That passes op = "time" and over = "median", and garry's time axis is "t", not "time". Copied as written, it errors. The example is \dontrun, so check never catches it.

**Evidence.** R/ocm.R:92 and man/ocm.Rd:98: composite <- ds |> reduce_over("time", "median") |> collect(). The signature is reduce_over(x, op, over, nan_rm = TRUE, bands = NULL).

**Suggested fix.** Change to reduce_over("median", over = "t").

**Verifier.** R/ocm.R:92 has reduce_over("time", "median"). The signature is reduce_over(x, op, over, ...), so op='time' and over='median'; the call is wrong both in argument order and in the axis name. The example is wrapped in \dontrun.

### 48. Internal plumbing exported under public-looking names
`R/ops.R:271` · package-docs · api

**Problem.** Several functions are tagged @keywords internal but exported without a dot prefix: g_jit, g_value_and_gradient, g_quantize, g_round, g_clamp, g_upload_raw, g_download_raw, gdal_pixel_extract, gdal_version_num, gdal_version_str and as_vaster_extent. They sit in the global namespace next to the documented g_* vocabulary, yet the pkgdown index hides them. Removing them after release breaks users, and keeping them freezes internals. as_vaster_extent is used nowhere in R/ (only in one test). g_round/g_clamp are generally useful map-body ops but are excluded from the documented vocabulary, which is inconsistent.

**Evidence.** Topics whose aliases are in NAMESPACE but carry keyword internal: as_vaster_extent, g_clamp, g_download_raw, g_jit, g_quantize, g_round, g_upload_raw, g_value_and_gradient, gdal_pixel_extract, gdal_version_num, gdal_version_str. Package code reaches only g_jit/g_upload/g_download via garry::.

**Suggested fix.** Dot-prefix the daemon/bridge-only ones (g_jit, g_value_and_gradient, g_quantize, g_*_raw, gdal_version_*, gdal_pixel_extract), or stop exporting them where daemons do not need them. Drop as_vaster_extent's export. Promote g_round/g_clamp into the documented vocabulary if they are meant for users.

**Verifier.** All 11 names are export()ed in NAMESPACE, and each Rd carries keyword{internal}. as_vaster_extent is defined in R/grid.R:398 but never called in R/ outside comments. gdal_pixel_extract is called only internally by extract_points.

### 49. plan_view example and the Inspecting plans article build a focal pipeline that cannot execute
`R/plan_view.R:396` · package-docs · docs

**Problem.** Both the plan_view() example and vignettes/articles/inspecting-plans.Rmd use focal(lr * 2, radius = 1L, fn = g_mean). focal() passes `fn` a list of shifted arrays, and g_mean() expects an array, so collecting this pipeline fails. The docs present a canonical pipeline that only works for drawing, never for running.

**Evidence.** collect(focal(r * 2, radius = 1L, fn = g_mean), distributed = FALSE) warns "mean.default ... argument is not numeric", then errors "Expected arrayish value, but got <numeric>".

**Suggested fix.** Use a valid stencil body, e.g. fn = function(sh) Reduce(`+`, sh) / length(sh), as in the getting-started vignette.

**Verifier.** R/plan_view.R:396 and inspecting-plans.Rmd:42 both use focal(..., fn = g_mean). focal documents that fn receives a LIST of shifted arrays. g_mean (R/ops.R:897) calls .g_traced(x) and then .g_reduce on the list, which cannot work, so the pipeline is only valid for drawing.

### 50. Inconsistent argument names across sibling public verbs
`R/scan_kalman.R:408` · package-docs · api

**Problem.** Sibling functions name the same concepts differently: kalman_smooth(outputs =, dtype =) versus kalman_llt(output =, out_dtype =). Axis arguments are lazy_stack(along =) versus reduce_over/scan_over/fill_gaps(over =). extract_points() takes `raster` as its first argument where every other verb takes `x`. lazy_stac_stack() takes a singular `asset`, has no `resampling` argument (lazy_source and lazy_dataset both have one), and returns a list(stack, slices, index) rather than a lazy object. These are cheap to fix now and costly after a stable release.

**Evidence.** args(): kalman_smooth(x, sigma_lvl, sigma_slp, sigma_obs = 1, obs_var = NULL, boundaries = NULL, outputs = c("mean","sd"), dtype = "f32", ...); kalman_llt(..., output = c("mean","sd","fmean","fsd","innov"), ..., out_dtype = "f32"); extract_points(raster, xy, ...); lazy_stack(xs, along = "t").

**Suggested fix.** Harmonise before tagging: one of output/outputs, dtype everywhere, x as the first argument, and a single axis-argument name (or document why along differs). Either give lazy_stac_stack a resampling argument and a lazy return type, or mark it internal/superseded by lazy_dataset().

**Verifier.** The signatures match the report: kalman_llt(output=, out_dtype=) at R/scan_kalman.R:90-100 versus kalman_smooth(outputs=, dtype=) at :408-418. extract_points(raster, ...) is at R/extract_points.R:65, lazy_stack(xs, along=) at R/lazy_raster.R:297, and fill_gaps/reduce_over/scan_over use over=. lazy_stac_stack (R/stac.R:781) takes asset with no resampling argument and returns list(stack, slices, index) (line 835).

### 51. write_tif() leaves a partially written destination file when execution fails
`R/write_tif.R:186` · package-docs · bug

**Problem.** With cog = FALSE, write_tif() streams directly into `path`. If execution errors partway, the destination stays on disk holding whatever has been written (zeros for unwritten blocks) and no nodata tag. The docs promise that `path` never holds a half-written file for cog = TRUE only, so a later reader cannot tell a failed non-COG write from a valid one.

**Evidence.** write_tif(r + 0, o, dtype = "i16") on input containing NaN, with no nodata, errors "result contains nodata (NaN) but no `nodata` sentinel was given". Afterwards the file exists as Int16 with values 0 0 0 0 and nodata NA.

**Suggested fix.** On error, unlink the destination(s) (on.exit guarded by a success flag), or stream to a sibling temp file and rename on success as the COG path already does.

**Verifier.** In R/write_tif.R, when cog is FALSE, work is path and .collect_impl writes straight to it; the function returns without any on.exit cleanup of path on error. Only the COG temporary is unlinked (docs at lines 29-34). A failed run therefore leaves a partial file and can clobber a prior valid file. Many raster writers behave the same way, so I kept the severity at medium.

### 52. Only 5 of 177 Rd pages have examples, and 4 of those are \dontrun
`man/collect.Rd:1` · package-docs · docs

**Problem.** None of the core user verbs has an example: collect, lazy_source, lazy_dataset, lazy_map, focal, reduce_over, mask, write_tif, scan_over, align. The only runnable example is grid_from_bbox; extract_points, plan_view, grid_from_src and ocm are \dontrun. As a result, R CMD check exercises no documented usage. That is how the broken ocm and plan_view examples above went unnoticed. The inspecting-plans article already shows a small local GeoTIFF fixture that could serve runnable examples.

**Evidence.** grep -L '\\examples' man/*.Rd | wc -l gives 172 of 177. Files with examples: extract_points, grid_from_bbox, plan_view, grid_from_src, ocm.

**Suggested fix.** Add small runnable examples built on a tempfile GeoTIFF for the core verbs, at least plan-only or distributed = FALSE collects. Keep \dontrun for network/STAC only.

**Verifier.** 177 Rd files exist and only 5 contain \examples (plan_view, grid_from_bbox, ocm, extract_points, grid_from_src). None of the core verbs have examples.

### 53. cgroup limit read only from the leaf cgroup; ancestor limits (SLURM job, systemd slice) are ignored
`R/pools.R:53` · scheduler-pools · bug

**Problem.** The probe reads memory.max only in the process's own cgroup directory and returns NA when it is 'max'. Limits are often set on an ancestor: SLURM's cgroup/v2 plugin limits the job/step cgroup while tasks live in .../step_N/user/task_N, and systemd MemoryMax is often placed on a slice (user@.service, a custom slice) rather than the leaf scope. In those cases the function returns NA, the budget falls back to host-wide free RAM (tens of GB), and the scheduler overcommits straight into the cgroup OOM killer. The comment says this case is handled ('a SLURM/systemd scope').

**Evidence.** base <- file.path('/sys/fs/cgroup', sub('^/', '', rel)); f_max <- file.path(base, 'memory.max'); if (identical(mx, 'max')) return(NA_real_). There is no walk up the hierarchy. The current cgroup here is .../user@1000.service/app.slice/app-positron-5938.scope with memory.max = max.

**Suggested fix.** Walk from the leaf up to /sys/fs/cgroup, computing (memory.max - memory.current) at every level that has a finite memory.max, and take the minimum, applying the same reclaimable-cache correction at each level.

**Verifier.** The probe reads memory.max only in the leaf cgroup directory (pools.R:53-62) and returns NA on 'max'; it never walks up the hierarchy. A limit set on a SLURM step/job cgroup or on a parent slice is therefore missed, and the budget falls back to host free RAM. The project's own systemd-run --scope -p MemoryMax workflow puts the limit on the leaf, so that case works. The header comment's SLURM claim is only true when the limit sits on the leaf.

### 54. cgroup headroom counts reclaimable page cache as used memory, flooring every budget in confined runs
`R/pools.R:70` · scheduler-pools · performance

**Problem.** .garry_cgroup_avail_mb() returns memory.max - memory.current. In cgroup v2, memory.current includes the file page cache, and the kernel only reclaims that cache when the cgroup reaches its limit. Inside a systemd-run scope, container or SLURM step that has read some GB of rasters, memory.current sits near memory.max even though most of it is reclaimable. .garry_ram_avail_mb() takes min(host, cgroup), so the reported availability collapses toward 0. In refresh_mem_budgets, cb then floors at task_mb_max and rb at store_mb_max (via both the pool and the shm/cgroup clamp), so the scheduler runs one compute task at a time. The flush_drops(force = TRUE) path also fires on every refresh. Placement also receives this avail_mb and refuses fusion. This is the same class of defect as the Darwin freeram bug the file already fixes for macOS, and it affects the confined-scope workflow the project relies on.

**Evidence.** The current cgroup on this machine reports memory.current = 14.0 GB, of which memory.stat shows anon 3.8 GB, file 9.6 GB and inactive_file 6.3 GB. Under a 16 GB MemoryMax, the code would report about 1.9 GB available while about 9 GB is reclaimable. Code: max(0, (mx - cur) / 2^20).

**Suggested fix.** Read memory.stat and treat inactive_file (and arguably active_file) as available: avail = memory.max - memory.current + inactive_file. Do not count shmem/anon as available. Add a unit test with injectable file contents, like .garry_darwin_avail_mb.

**Verifier.** pools.R:70 returns max(0, (memory.max - memory.current)/2^20), and .garry_ram_avail_mb (pools.R:137-144) takes min(host, cgroup). In cgroup v2, memory.current includes reclaimable file cache, so in a scope that has read local rasters the headroom falls toward zero and the budgets drop to their floors. The /dev/shm (mori) portion of memory.current is not reclaimable, so that part of the count is correct. The effect is lost throughput in confined runs, not wrong results, so I rate it medium rather than high.

### 55. garry.daemon_gc_mb never reaches the daemons it configures
`R/scheduler.R:282` · scheduler-pools · bug

**Problem.** daemon_gc_mb is documented as daemon-side hygiene ('MB of task transients between daemon gc + malloc_trim passes'), and .daemon_gc_after() reads garry_opt('daemon_gc_mb') inside the daemon process. Daemons do not inherit host options, though. The run-start broadcast ships only garry.read_fail and garry.read_retry, and garry_daemons() ships only handle_cache_max and gdal_cachemax_mb. Setting options(garry.daemon_gc_mb = ...) on the host passes .garry_opt_check() and appears as 'set' in garry_options(), yet the daemons always run with the default 128. Relatedly, garry_pool_hygiene's docs say the scheduler 'trims after every compute/write task', which contradicts the deferred-gc design.

**Evidence.** scheduler.R:279-288 broadcasts options(garry.read_fail = rf, garry.read_retry = rr) only. daemon.R:41: if (acc < garry_opt('daemon_gc_mb') * 2^20). The grep shows no other place that ships daemon_gc_mb.

**Suggested fix.** Add garry.daemon_gc_mb (and any other daemon-read options) to the run-start options() broadcast. Fix the garry_pool_hygiene docs to say trimming is batched by garry.daemon_gc_mb.

**Verifier.** The daemon reads garry_opt('daemon_gc_mb') in-process at daemon.R:41. The only places that set options on daemons are the run-start broadcast (scheduler.R:279-288: read_fail and read_retry only) and garry_daemons (handle_cache_max and gdal_cachemax_mb only). A grep finds no other path that ships daemon_gc_mb, so a host-side setting never reaches the daemons. Separately, the garry_pool_hygiene docs (pools.R:607-609) say the scheduler 'trims after every compute/write task', which contradicts the deferred gc in .daemon_gc_after.

### 56. run_id is drawn from the user's RNG stream, so collect() changes .Random.seed and seeded sessions collide on the fetch directory
`R/scheduler.R:291` · scheduler-pools · bug

**Problem.** run_id <- as.integer(stats::runif(1, 1, 1e8)) consumes the caller's RNG. A distributed collect() therefore changes every later random draw in the user's script (non-reproducible relative to distributed = FALSE), and it creates .Random.seed if none existed. Worse, two concurrent sessions that both call set.seed(k) before collecting (for example array jobs on one node) get the same run_id. They then share fetch_root = /dev/shm/garry-fetch-{run_id}. dir.create only warns, both sessions fetch into the same i1/r0001.tif paths and rewrite the same local GTI index, and whichever finishes first unlink()s the whole tree under the other. Under read_fail = 'nodata' that becomes a silent hole.

**Evidence.** run_id <- as.integer(stats::runif(1, 1, 1e8)); fetch_root <<- file.path(base, .glue('garry-fetch-{run_id}')); dir.create(fetch_root); on.exit(unlink(fetch_root, recursive = TRUE)).

**Suggested fix.** Derive the id without touching the RNG, e.g. paste(Sys.getpid(), a per-session counter, a nanotime). Create fetch_root with tempfile(pattern = 'garry-fetch-', tmpdir = base) and check dir.create's return value.

**Verifier.** scheduler.R:291 draws run_id with stats::runif, which consumes the user's RNG stream. The run_id names fetch_root /dev/shm/garry-fetch-{run_id} (scheduler.R:417-418), and that directory is shared across processes on the node. dir.create only warns if the directory exists, and on.exit unlinks the whole tree. Two sessions seeded identically on one node therefore collide. Daemon registry names reuse run_id too, but daemons are per-session, so only the fetch directory is at risk.

### 57. Eager fetch-cache unlink is per stage, but fetched files are shared across stages
`R/scheduler.R:2209` · scheduler-pools · bug

**Problem.** Fetch tasks are deduplicated globally by (index, row) through fetch_made, and all stages reading the same GTI index share fetch_state's dst files. Cleanup, however, is tracked per stage: fetch_files_of[[sid]] holds that stage's files, and the first stage to finish its last assemble unlinks them. If two source_read stages address the same GTI index and slice (for example two SourceNodes on one index differing only in band, nodata or scale, or read_coalesce = FALSE on a multi-band index), the second stage's pending assembles find the files gone. They fail, or under read_fail = 'nodata' they silently read a hole. The second stage's fetch extent/decimation is also taken from whichever stage created the fetch key first.

**Evidence.** fetch_made[[key]] <- TRUE (global dedup); fetch_files_of[[.key(s@id)]] <- fp$files; if (left <= 1L) { unlink(fetch_files_of[[sk]]) }.

**Suggested fix.** Refcount fetched files across all consuming read tasks, e.g. a per-file counter incremented in prepare_fetch for every stage and decremented per completed assemble, and unlink at zero. Alternatively, key fetch dedup by stage when sharing is unsafe.

**Verifier.** fetch_made dedups fetches globally by f{index id}_{row} (scheduler.R:460-463), but fetch_files_of and fetch_reads_left are keyed per stage. When the first stage finishes its last assemble it unlinks files that other stages still reference (scheduler.R:2205-2210). The fetch extent and target_res also come from whichever stage created the key first (s@grid in prepare_fetch). The scenario is reachable whenever two source_read stages use the same GTI index and slice: separate bands of a multi-band asset not collapsed into a stack, or the same asset on two different grids. Under read_fail='nodata' this can give silent holes, so I rate it above the reported low.

### 58. garry_task_report merges launch/done rows by key, producing a cross product for logs that span several runs
`R/task_report.R:48` · scheduler-pools · bug

**Problem.** The scheduler appends to garry.task_log and writes the header only on a fresh file, so one log routinely holds several runs. Task keys (s3_c1, f1_2, ...) restart every run, so merge(la, do, by = 'key') pairs every launch of a key with every done of that key. n runs give n^2 rows per key, with run_s values that are negative or span runs. Stage counts, p50/p95 and 'launch/done pairs' are then wrong. drain_s also uses min(time) over the whole file against max(drain_end), so it measures from the first run's start to the last run's drain.

**Evidence.** tasks <- merge(la, do, by = 'key'); t0 <- min(df$time); drain_s <- round(max(t_drain) - t0, 3). The scheduler writes the header only when !file.exists(task_log) || file.size(task_log) == 0 and appends otherwise.

**Suggested fix.** Split the log into runs at drain_end/host_end boundaries, or log the run_id as a column. Match each launch to the next done of the same key in time order within a run, and report per run or the last run by default.

**Verifier.** The log appends across runs: the header is written only on a fresh file (scheduler.R:1918), and stage task keys repeat between runs. merge(la, do, by='key') at task_report.R:48 builds a cross product. I reproduced it: a log with two launch/done pairs for s1_c1 gives 4 task rows, one with run_s = -1. drain_s also measures from min(time) over the whole file.

### 59. preview() of a file reads every requested band at full resolution before decimating
`R/preview.R:378` · stac-views · performance

**Problem.** The docs say 'a file or an array is decimated to the device', but .pv_read_path() calls gdal_read_window(path, bi, 0, 0, nx, ny) at native size and decimates afterwards in R. A 10980 x 10980 Sentinel-2 band is about 1 GB as numeric per band, and about 3 GB for an RGB preview. On a remote COG this also fetches every full-resolution tile instead of overviews. gdal_read_window already supports a `decim` argument and GDAL RasterIO can downsample in a single pass.

**Evidence.** `layers <- lapply(b, function(bi) gdal_read_window(path, bi, 0L, 0L, nx, ny))`, then `.pv_decimate(arr, target)`.

**Suggested fix.** Read directly at the target size, for example ds$read(band, 0, 0, nx, ny, out_nx, out_ny), or go through the decim path so GDAL uses overviews.

**Verifier.** preview.R:378 calls gdal_read_window at full nx x ny with no decim, even though gdal_read_window has a decim argument (gdal_adapter.R:407). Decimation happens afterwards in R.

### 60. stac_sign_mpc() signs every item with the first item's collection token
`R/stac.R:103` · stac-views · bug

**Problem.** Only one token is requested, for items$features[[1]]$collection, and it is applied to every asset. stac_merge() accepts doc_items and is documented for HLS L30 + S30 harmonisation, so stac_merge(l30, s30) |> stac_sign_mpc() is a natural order. Items from the second collection, which is generally a different storage container, then carry a token that is not valid for them, and the reads fail with 403 at execution time. Not retriable. A feature with no `collection` field also errors inside exists(NULL).

**Evidence.** `token <- .mpc_token(items$features[[1L]]$collection, subscription_key)` followed by an unconditional lapply over all features and assets.

**Suggested fix.** Request one token per distinct f$collection, which is still one request per collection through the cache, and sign each feature with its own token. Abort with a clear message when a feature has no collection.

**Verifier.** stac.R:103 requests one token for features[[1]]$collection and applies it to every asset. stac_merge does accept doc_items (stac.R:644-654), so a merged multi-collection doc_items gets a single collection's SAS token.

### 61. Token cache returns tokens with seconds left, which defeats .mpc_resign()'s expiry margin
`R/stac.R:230` · stac-views · bug

**Problem.** .mpc_resign() decides a URL needs re-signing when its token is within `margin` (600 s) of expiry. It then calls .mpc_token(account/container), and .mpc_token_lookup() returns any cached token with exp > Sys.time(), with no margin. From the second token lifetime of a long run onwards, the cached container token is the same near-expiry token, so the 'fresh' URL carries a token with less than 600 s, possibly seconds, left. Chunk reads dispatched in that window can hit non-retriable 403s mid-read, which is the failure the resign hook exists to prevent. The tests mock .mpc_token, so this interaction is never exercised.

**Evidence.** unexpired <- function(tok) { ...; !is.na(exp) && exp > Sys.time() } (lines 224-231) versus `se - margin > as.numeric(Sys.time())` in .mpc_resign (line 177). test-mpc-resign.R mocks .mpc_token entirely.

**Suggested fix.** Give .mpc_token_lookup() a margin argument (for example 600 s, or the margin passed from .mpc_resign) and treat tokens inside it as expired. Add a test that runs two resign cycles against the real cache with a mocked HTTP layer.

**Verifier.** .mpc_token_lookup's unexpired() checks only exp > Sys.time(), with no margin. After the first container token has been cached, .mpc_resign can 're-sign' with that same near-expiry token. The tests mock .mpc_token.

### 62. Antimeridian-crossing STAC items are rejected outright
`R/stac.R:266` · stac-views · bug

**Problem.** The STAC/GeoJSON spec encodes an antimeridian-crossing bbox with xmin > xmax. .check_bbox() requires xmin < xmax, and stac_sources() runs it on every item. A single such item in a search over Fiji, Chukotka or the Aleutians aborts stac_sources(), and with it lazy_dataset(), with a 'malformed bbox' error. stac_filter_coverage() aborts the same way on doc_items. The default solar_day lon (a circular mean) suggests antimeridian support was intended.

**Evidence.** stac_sources() on an item with bbox c(170, 0, -170, 1) gives: "bbox of STAC item \"a\" must be finite `c(xmin, ymin, xmax, ymax)` with xmin < xmax ...".

**Suggested fix.** Accept xmin > xmax for item bboxes in EPSG:4326, either by splitting into two footprints or by unwrapping xmax + 360 for the index and coverage maths. At minimum, abort with a message that names the antimeridian case.

**Verifier.** Reproduced: stac_sources on an item with bbox c(170,0,-170,1) aborts in .check_bbox with the malformed-bbox error.

### 63. Items with null `datetime` are silently dropped from stacks and datasets
`R/stac.R:794` · stac-views · bug

**Problem.** STAC allows datetime = null when start_datetime/end_datetime are given (common for composites and some DEM and land-cover collections). stac_sources() stores NA and ignores start_datetime. stac_time_slices('day'/'month'/'exact') then yields NA slices, and lazy_stac_stack() and lazy_dataset() (dataset.R:326) build their slice list with sort(unique(...)), which drops NA. Those items vanish with no warning. 'solar_day' instead errors with 'unparseable STAC datetime(s): NA'.

**Evidence.** stac.R:320 `datetime = ft$properties$datetime %||% NA_character_`; stac.R:794 and dataset.R:326 `slices <- sort(unique(sources$slice[...]))`, where sort() removes NA by default.

**Suggested fix.** In stac_sources(), fall back to properties$start_datetime when datetime is null, and warn or abort when slices contain NA rather than dropping them silently.

**Verifier.** stac.R:320 stores NA for a null datetime and start_datetime is ignored. stac_time_slices gives day/month/exact slices of NA, and sort(unique()) at stac.R:794 and dataset.R:326 drops them silently. solar_day errors via .stac_parse_datetime.

### 64. No tests for the risky preview/STAC paths found above
`tests/testthat/test-preview.R:66` · stac-views · test-gap

**Problem.** The file path test passes only bands = 1, which hides the band-index bug. No test checks that a coarse preview preserves scale/offset or produces values that agree with collect(). stac_query() has no offline test of the datetime string it builds, which would have caught the end-date exclusion. The resign tests mock .mpc_token, so the interaction between the cache and the expiry margin is untested. Nothing covers multi-collection signing.

**Evidence.** test-preview.R:66 `expect_error(preview(out, bands = 1), NA)`; test-mpc-resign.R mocks .mpc_token in every resign test; no test file calls stac_query offline.

**Suggested fix.** Add tests for: preview(file, bands = c(3,2,1)); a coarse preview of a scaled source against decimated collect(); the datetime interval string from stac_query (mocking rstac::stac_search); two resign cycles with only HTTP mocked; stac_sign_mpc on a merged two-collection doc_items.

**Verifier.** The bugs above (multi-band file preview, coarse scale/offset loss, end-date formatting, cache-margin interaction, multi-collection signing) have no covering tests. The resign tests mock .mpc_token.

### 65. Dataset verbs accept unknown band names and silently create empty or NA bands
`R/dataset.R:601` · user-api · api

**Problem.** .ds_map/.ds_focal iterate `bands` without checking membership. lazy_map(ds, fn, bands = "typo") adds a new band 'typo' with zero layers, which fails later in collect with an unrelated 'needs one layer per band' message. `[` (line 540) with an unknown name yields a band named NA holding NULL, which the LazyDataset validator accepts. .ds_reduce/.ds_scan with a bad name fail with 'is.list(xs) is not TRUE'.

**Evidence.** lengths(lazy_map(d, fn = function(v) v + 1, bands = "typo")@bands) is a=1 b=1 typo=0; names(d[c("a","typo")]@bands) is "a" NA (verified).

**Suggested fix.** Validate `bands`/`i` against names(x@bands) in one helper used by every dataset verb and `[`. Have the class validator reject NA names and empty or non-LazyRaster band entries.

**Verifier.** Reproduced: lazy_map(d, bands='typo') gives band lengths a=1 b=1 typo=0, and d[c('a','typo')] has band names 'a' NA. Neither .ds_map nor [ checks band membership.

### 66. reduce_over(ds, op, "band") folds the QA/mask band into the band reduction
`R/dataset.R:648` · user-api · bug

**Problem.** With bands = NULL, .ds_reduce over "band" stacks every band, including an undropped mask_asset, so a band mean or median mixes QA codes with reflectances. The t reduction also defaults to all bands, reducing the QA band with e.g. median and keeping it as mask_asset. lazy_map, focal and fill_gaps default to value bands only, so the defaults are inconsistent.

**Evidence.** stack_bands(if (is.null(bands)) x else x[bands]) with no exclusion of x@mask_asset; sel <- bands %||% names(x@bands) at line 654.

**Suggested fix.** Default to .ds_value_bands(x) for the band reduction at least, and preferably for every dataset verb. Document the mask band handling.

**Verifier.** .ds_reduce over 'band' calls stack_bands(x) with no exclusion of mask_asset, and stack_bands does not drop it either. The t path uses names(x@bands), whereas map, focal and fill_gaps use value bands, so the defaults are inconsistent.

### 67. Exported mask() and grid accessor generics mask terra/dplyr functions
`R/dataset.R:1041` · user-api · api

**Problem.** garry exports mask, res, xmin, xmax, ymin, ymax (S7 generics with no default method, grid.R:363-383) and collect. These collide with terra::mask/res/xmin..., which as_terra() users will have attached, and with dplyr::collect. Whichever package is attached last breaks the other: res(spatraster) under garry fails with "Can't find method for `res(<...>)`", and collect(lazy) under dplyr fails dispatch. Renaming after v0.1.0 would be costly.

**Evidence.** res(1:3) with garry loaded -> "Can't find method for `res(<integer>)`." (verified)

**Suggested fix.** Before release, rename to collision-free verbs (e.g. mask_qa) or register methods on the existing terra/dplyr generics. At minimum, give the S7 generics a default method that falls through to the other package's function.

**Verifier.** NAMESPACE exports mask, res, xmin, xmax, ymin, ymax and collect. xmin and res are S7 generics with no default method (grid.R:363-383), so they mask terra's and dplyr's functions. Renaming these after the stable release would be costly.

### 68. Unary minus, !, &, |, %/%, Summary and logical scalars on LazyRaster fail with opaque errors
`R/lazy_raster.R:487` · user-api · api

**Problem.** Only binary + - * / ^ %% and comparisons are registered. -x fails with 'argument "e2" is missing', !x with 'attempt to apply non-function', x & y with an S7 dispatch error, and max(x) with 'invalid type (object)'. x + NA and x * TRUE (logical, not class_numeric) fall through to base with 'non-numeric argument to binary operator'. Length > 1 numeric scalars (x + c(1,2)) are accepted at construction and fail only at collect with 'Expected arrayish input'. These are basic operations for a stable array API.

**Evidence.** Verified outputs: (-x) -> "argument \"e2\" is missing, with no default"; collect(!x) -> "attempt to apply non-function"; collect(x + c(1,2)) -> "Expected arrayish input, but got <numeric>".

**Suggested fix.** Register unary - (and +), and decide on !, &, | (0/1 f32 masks to match comparisons). Give Summary a pointer to reduce_over(). Accept logical scalars and reject non-length-1 scalars at construction with a cli error.

**Verifier.** Reproduced: -x errors 'argument "e2" is missing', collect(!x) errors 'attempt to apply non-function', x+c(1,2) fails only at collect, and x+NA fails with a base error. Only + - * / ^ %% and comparisons are registered.

### 69. Comparison operators turn nodata (NaN) into a valid 0
`R/lazy_raster.R:521` · user-api · bug

**Problem.** Comparisons are wrapped in g_cast(f(x, y), "f32"), and NaN compares false, so every nodata pixel becomes a valid 0 in the mask. A downstream nan_rm reduction then counts nodata as 'false'. For example, reduce_over(ndvi > 0.3, "mean", "t"), meant as the fraction of valid observations above a threshold, is biased low by every cloudy or missing slice. x == x is 0 at nodata. R semantics (NA > 5 is NA) and the package's own NaN-as-nodata convention both suggest propagating NaN.

**Evidence.** lazy_source(i16.tif, nodata = 1) > 5 collects to 0 at the nodata pixel; xn == xn gives 0 there (verified).

**Suggested fix.** Emit g_ifelse(g_is_nodata(x) | g_is_nodata(y), NaN, cast(cmp)). Otherwise document clearly that masks are nodata-blind and provide a nodata-preserving variant.

**Verifier.** Comparisons are wrapped in g_cast(f(x,y),'f32') with no NaN guard. Reproduced: a nodata pixel collects to 0 for xn > 5. The 0/1 mask design is intentional, but dropping nodata is undocumented and biases nan_rm reductions. Rated medium because it is a semantic choice rather than a crash.

### 70. align() accepts targets and inputs it cannot honour; default resampling differs from the readers
`R/lazy_raster.R:1104` · user-api · api

**Problem.** With `to` a LazyRaster, align copies its full grid including t/band dims. align(x2d, cube) declares (x, y, t=2) but collects a 4x4 array, so the declared grid lies to every downstream grid_equal check. align(cube, grid2d) drops t from the declared grid. Aligning any computed raster is accepted and fails only at collect ('warping a computed raster is not supported in v1'). Separately, align defaults to resampling = "bilinear" while lazy_source and lazy_dataset default to "near" and are documented as preserving exact values. A categorical/QA raster aligned with the default is silently interpolated, and resampling is not validated here, unlike lazy_dataset's table form.

**Evidence.** align(x, st)@grid@dims is x=4 y=4 t=2 but dim(collect(.)) is 4 4; align(st, tg) constructs and then errors at collect (verified).

**Suggested fix.** Strip non-spatial dims from the target (keep x's own). Reject non-source inputs at construction with the v1 message. Validate resampling against the shared method list. Consider "near" as the default, for consistency with the readers.

**Verifier.** Reproduced: align(x2d, cube)@grid@dims is x y t=2 while collect gives 4x4. The formals show resampling defaults to 'bilinear', while the readers default to 'near'.

## Low (57)

### 71. collect() results never carry band names, so as_terra()'s promise to preserve names is never met
`R/collect.R:217` · executor-daemons · docs

**Problem.** as_terra() copies names from dimnames(x)[[3]] and its docs say 'Band names/descriptions are preserved when present'. Neither .collect_layout() nor .collect_impl() sets dimnames, so even a named lazy_stack or LazyDataset collects to an unnamed array, and terra falls back to lyr.1, lyr.2.

**Evidence.** collect(lazy_stack(list(red=..., nir=...), along='band')) has dimnames NULL, and as_terra() gives names 'lyr.1' 'lyr.2'.

**Suggested fix.** Set dimnames(out)[[3]] from band_names or the grid's layer labels in .collect_impl (and in the multi-sink branch), or drop the claim from the as_terra() docs.

**Verifier.** dimnames is never set anywhere in R/ (the only reference is as_terra's read at collect.R:217). .collect_layout only aperms, so band-stack results are unnamed and as_terra's name preservation never triggers for collect output.

### 72. garry.daemon_gc_mb is read only on daemons but never shipped to them
`R/daemon.R:41` · executor-daemons · bug

**Problem.** .daemon_gc_after() consults garry_opt('daemon_gc_mb'), and it runs only inside daemon task bodies. Daemons do not inherit host options. The scheduler broadcast ships only read_fail and read_retry, and pools.R ships only handle_cache_max and gdal_cachemax_mb. Setting options(garry.daemon_gc_mb = ...) on the host, as garry_options() advertises for this tuning option, therefore has no effect and daemons always use the default of 128.

**Evidence.** grep shows daemon_gc_mb referenced only in options.R and daemon.R:41. scheduler.R:280-288 and pools.R:570-577 broadcast other options only.

**Suggested fix.** Add garry.daemon_gc_mb to the pools.R start-up broadcast or the per-run .pool_broadcast.

**Verifier.** daemon_gc_mb is referenced only in options.R:134 and daemon.R:41. The broadcasts ship only read_fail/read_retry (scheduler.R:282, composite_direct.R:474) and handle_cache_max/gdal_cachemax_mb (pools.R:570). garry_opt on a daemon therefore reads the default.

### 73. Daemon task bodies are exported, dot-prefixed functions in the stable public namespace
`R/daemon.R:82` · executor-daemons · api

**Problem.** More than a dozen internal task bodies (.daemon_hygiene, .daemon_run_source_shm, .daemon_write_chunk, .gd_compute_masked_band, .cd_fetch_warp, .garry_abi_token, ...) are @export-ed only so daemons can call them via garry::. After v0.1.0 they become part of the exported API surface, and their formals are deliberately versioned through the ABI token. garry::: (or a single exported dispatcher) would reach them without committing to them publicly.

**Evidence.** Each `#' Internal (exported only so mirai daemons can address it via ::)` block carries @export.

**Suggested fix.** Call them via garry::: from mirai bodies (R CMD check allows ::: on one's own package inside quoted expressions), or route all daemon calls through one exported .garry_daemon_call(name, ...) entry point.

**Verifier.** NAMESPACE exports about 20 dot-prefixed daemon task bodies (.daemon_*, .gd_*, .cd_fetch_warp, .garry_abi_token). The export exists to avoid the R CMD check NOTE on ':::' calls into the package's own namespace, so it is a deliberate trade-off. They are hidden from ls() but part of the namespace surface. Low.

### 74. Writer close errors are discarded, so a failed final flush can report a successful write
`R/daemon.R:505` · executor-daemons · bug

**Problem.** .daemon_write_close() wraps each handle's $close() in try(silent = TRUE). For streamed GTiff writes the close is where GDAL flushes the remaining dirty, DEFLATE-compressed tiles from the writer's block cache (see the 2026-08-13 note: data 'sat in the writer's block cache'). Any error raised there, such as ENOSPC or an I/O failure, is dropped, the host's normal-path everywhere(...) receives NULL, and write_tif() returns the path as if the file were complete. The host-side single-threaded writer does surface close errors, so the two routes differ.

**Evidence.** `for (p in ks) { try(.daemon_ds[[p]]$close(), silent = TRUE) }` returns invisible(NULL) regardless, and scheduler.R:2269-2272 only waits on the result.

**Suggested fix.** Collect close errors and return them (e.g. a character vector of failed paths), and have the host abort on them in the normal path. Keep try() only on the abort path.

**Verifier.** daemon.R:505-507 wraps each $close() in try(silent=TRUE) and returns NULL, while the host writer uses on.exit(ds$close()) and surfaces close errors. Downgraded: most I/O failures surface during block writes, before the final flush, and GDAL flush failures often come back as CPL warnings rather than R errors.

### 75. Dead or stale code in the daemon and executor layer
`R/executor.R:287` · executor-daemons · dead-code

**Problem.** .sv_to_int() is an alias for .sv_to_vec() and is referenced only from tests/testthat/test-raw-store.R. .cd_fetch_warp() always returns tf = 0 (daemon.R:1040), a leftover from the removed fetch phase, yet composite_direct.R:548-551 still sums and prints 'fetch=0.0s' in its progress line, which misleads anyone reading timings.

**Evidence.** grep finds no package-code caller of .sv_to_int. `list(err = err, tf = 0, tw = tw)`.

**Suggested fix.** Delete .sv_to_int (point the test at .sv_to_vec), and drop tf from .cd_fetch_warp and the progress message.

**Verifier.** The only caller of .sv_to_int is tests/testthat/test-raw-store.R:223. .cd_fetch_warp returns tf = 0 (daemon.R:1044), and .gd_warp_collect still sums and prints 'fetch=...s' (composite_direct.R:548-551).

### 76. write_tif() returns the directory, not the per-sink files, for the directory form, contradicting @return
`R/executor.R:945` · executor-daemons · docs

**Problem.** @return for write_tif() says 'The written path(s), invisibly (expanded per sink/group for list, directory, and {group} forms)'. For the multi-sink directory form, .exec_sink_tail returns invisible(path), which is the directory as given; the scheduler route does the same. Callers that use the return value to locate outputs get the directory. The COG branch works around this with list.files(), which also picks up unrelated .tif files already in that directory and would try to translate them.

**Evidence.** write_tif(list(a=x, b=x+1), existing_dir, distributed = FALSE) returned the bare directory path. write_tif.R:200-202 relies on list.files(p, '\\.tif$') for directories.

**Suggested fix.** Return the expanded named vector of per-sink files (the `p` values computed in the tail) and have the COG branch use it instead of list.files().

**Verifier.** .exec_sink_tail returns invisible(path) for multi-sink writes (executor.R:945), so the directory form returns the directory, not per-sink files, contrary to @return. The sub-claim that the COG branch's list.files picks up unrelated .tif files is wrong: for a directory target the work dir is a fresh tempfile subdirectory (write_tif.R:160-171), so list.files sees only streamed files. Downgraded to low.

### 77. Integer writes silently saturate out-of-range values, which can then collide with the nodata sentinel
`R/write_tif.R:21` · executor-daemons · bug

**Problem.** Quantized writes clamp to the dtype range on device (g_quantize, ops.R:277). Non-quantized integer writes pass doubles to GDAL, which saturates. Neither case warns, and the docs describe only round((v - offset) / scale). Valid data past the range becomes the range limit. If nodata sits at a range edge (e.g. -32768 for i16, 0 for u8), clamped valid pixels become indistinguishable from nodata. That is silent data corruption for a badly chosen scale.

**Evidence.** write_tif(lazy_source(f)*1000, dtype='u8') wrote all 255. write_tif(..., dtype='i8', scale=1) wrote all 127. Neither raised a warning.

**Suggested fix.** Count clamped pixels in g_quantize (it already downloads a NaN count in the no-nodata branch) and warn or abort when it is non-zero. Clamp to range minus the sentinel when nodata lies on an edge, and document the saturation.

**Verifier.** g_quantize clamps to the dtype range (ops.R:276-277) with no warning, and user-facing write_tif docs do not mention saturation. Downgraded: this matches GDAL's standard saturating conversion and needs a badly chosen scale or dtype. The nodata-collision consequence is real but is user misconfiguration.

### 78. write_tif() validation gaps: u32 quantization accepted then fails deep; nodata length, type and integrality unchecked
`R/write_tif.R:121` · executor-daemons · api

**Problem.** .wt_int_range lists u32, so write_tif(dtype='u32', scale=...) passes validation and then fails mid-execution in g_quantize with 'unsupported quantize dtype'. store.c's gdt_es and .sv_is_int do not know u32 either. Only the integer-dtype nodata path is range-checked, and it errors cryptically on a length-2 nodata ('length = 2 in coercion to logical(1)'). A non-numeric nodata gives '`nodata` (a) does not fit output dtype'. A fractional nodata for an integer dtype (1.5 for i16) is accepted. For float or NULL dtype, a length-2 nodata is silently dropped by gdal_create_output. i64/u64 dtypes skip the range check entirely.

**Evidence.** Checked with load_all: dtype='u32', scale=0.01 gives 'unsupported quantize dtype "u32"' after planning. nodata=c(1,2) gives "'length = 2' in coercion to 'logical(1)'". nodata=1.5 with dtype='i16' succeeds.

**Suggested fix.** Validate nodata as a single finite number (or NaN for floats), require an integral value for integer dtypes, drop u32 from the quantizable set or support it end-to-end, and validate dtype against the writable set before planning.

**Verifier.** .wt_int_range includes u32 (write_tif.R:9), but .g_int_range (ops.R:246-252) and store.c gdt_es do not, so dtype='u32' with scale passes validation and fails later in g_quantize. The range check `nodata < rng[[1]] || ...` (write_tif.R:121) errors cryptically for length-2 nodata and does not check integrality.

### 79. COG docs promise 'path never holds a half-written COG', but the translate writes directly to path
`R/write_tif.R:226` · executor-daemons · docs

**Problem.** Only the streamed intermediate is a temp file. gdal_translate_file(streamed, finals[[i]]) writes the COG straight to the final path, so an interrupted or failed translate (disk full, user interrupt) leaves a partial file at path. Nothing cleans it up, which contradicts the Details section.

**Evidence.** `ok <- gdal_translate_file(streamed[[i]], finals[[i]], cl)` and on.exit unlinks only `work`/tmp_dirs.

**Suggested fix.** Translate to a sibling temp name and file.rename() it onto the final path on success, or soften the documentation.

**Verifier.** write_tif.R:226 runs gdal_translate_file(streamed[[i]], finals[[i]]) straight onto the final path. An interrupted or failed translate leaves a partial file there, and nothing removes it. This contradicts the 'path never holds a half-written COG' Details text.

### 80. An aborted pipeline leaves fetch/compute tasks running and reuses the same per-pid tmp dir on the next run
`R/composite_direct.R:565` · gdal-io · bug

**Problem.** On any abort (.gd_fetch_fail, a harvest() miraiError, user interrupt), on.exit deletes tmp, but the queued and running mirai tasks are never cancelled. They keep occupying the read and compute pools, so the next collect queues behind them. .gd_tmp() names the directory only by host pid ('gdirect-<pid>'), and bins are named n<node id>.bin. A re-run in the same session therefore recreates the same directory, and orphaned fetch tasks from the aborted run can overwrite the new run's n<id>.bin files when node ids coincide, as they do for a re-planned graph of the same shape.

**Evidence.** L567-571: file.path(..., .glue('gdirect-{Sys.getpid()}')); dir.create(tmp). harvest() (L933) and .gd_fetch_fail (L528) abort without mirai::stop_mirai on the outstanding promises.

**Suggested fix.** Use a unique run dir (tempfile('gdirect-', tmpdir = base)), and on.exit stop_mirai() the outstanding fetch, mask and band promises.

**Verifier.** No mirai::stop_mirai anywhere in R/, and .gd_tmp names the directory by pid only. Orphaned tasks therefore keep occupying the pools after an abort (a real perf issue). The overwrite race is weaker than stated: re-collecting the same graph gives identical jobs (same node ids, same content), so an orphan writes identical bytes. Different content needs a different graph whose node ids coincide. Downgraded to low.

### 81. read_fail = 'nodata' does not hold on the gd routes when a fetch task dies, and the fmask progress line crashes on failed tasks
`R/composite_direct.R:663` · gdal-io · bug

**Problem.** .gd_fetch_fail only warns under read_fail = 'nodata'. For a transport failure (miraiError: daemon crash or OOM), .cd_fetch_warp never ran writeBin, so the .bin does not exist. The subsequent readBin (L663, L1122, or the band task in the pipeline) then errors with 'cannot open file' instead of filling with nodata. Separately, with garry.progress = TRUE the fmask timing line `vapply(fmr, function(r) r$tw, 0)` (L862) errors on a miraiError element, because `$` is invalid on an atomic vector.

**Evidence.** L555/L856 warn and continue; .cd_fetch_warp is the only writer of j$bin; L862 has no Filter() like the one .gd_warp_collect uses at L548.

**Suggested fix.** After a tolerated failure, write an all-NaN .bin for every failed source on the host (size ny*nx*4). Filter fmr to list results before summing tw.

**Verifier.** .cd_fetch_warp always writes the bin for caught errors, but a miraiError (daemon death) means it never wrote. .gd_fetch_fail only warns under read_fail = 'nodata', and the subsequent readBin of the missing file then errors. L862 vapply(fmr, function(r) r$tw, 0) has no Filter for miraiError elements, unlike .gd_warp_collect L548.

### 82. Pipeline does not check the mask task result before dispatching band tasks
`R/composite_direct.R:973` · gdal-io · bug

**Problem.** `mask_p[]` is evaluated only for its blocking side effect. If .gd_compute_mask fails (XLA error, OOM), every band task then fails reading the missing mask .bin. The user sees 'compute failed on band 1 strip 1: cannot open file ...mask...bin', which hides the real error.

**Evidence.** if (!mask_done) { mask_p[]; mask_done <- TRUE }

**Suggested fix.** v <- mask_p[]; if (inherits(v, 'miraiError')) cli::cli_abort('gdal-direct mask computation failed: {conditionMessage(v)}').

**Verifier.** L972-975: mask_p[] is evaluated and discarded. Its result is never checked for miraiError, nor is the returned error. Band strip tasks then fail on the missing mask .bin, hiding the root cause.

### 83. Raw-cube VRT XML interpolates band names, CRS and nodata without escaping
`R/gdal_adapter.R:788` · gdal-io · bug

**Problem.** .raw_bsq_vrt_xml glues descriptions[[b]] and wkt straight into XML. A band name containing '&', '<' or '>' (names come from dataset/stack labels) produces an invalid VRT. gdal_create_output('x.vrt', ..., band_names = 'NIR<0.5 & cloud') then fails to reopen with 'open raster failed', and the streamed write aborts. .gti_resampled_path (L1848) has the same pattern for the index path, and also hard-codes IndexLayer 'index' even though gti_index_create() accepts any `layer`.

**Evidence.** Probe: gdal_create_output(tempfile(fileext='.vrt'), g, band_names = 'NIR<0.5 & cloud') fails with GDAL 'Didn't find expected '=' for value of attribute '&'' and then 'open raster failed'.

**Suggested fix.** XML-escape (&, <, >, ") every interpolated value, and pass the layer name through to the .gti wrapper.

**Verifier.** .raw_bsq_vrt_xml glues descriptions[[b]] into <Description> unescaped (L788), and .gti_resampled_path (L1846-1851) glues the index path and hard-codes IndexLayer 'index'. A band name containing & or < yields invalid XML.

### 84. Raw-BSQ fast read does not bounds-check the window and returns short or zero-padded payloads
`R/gdal_adapter.R:960` · gdal-io · bug

**Problem.** For an out-of-range window (y_off + y_size > ny, or x beyond nx), readBin returns fewer bytes, raw out-of-range indexing yields 00, and the structure still claims gdim = c(y_size, x_size). The numeric branch recycles via matrix(). The GDAL path for the same request errors with 'Access window out of range', so the raw-cube path silently returns zeros or garbage. The partial-width index `(seq_len(y_size) - 1L) * (nx * 4L)` is integer arithmetic and overflows to NA (read as zero bytes) for y_size*nx*4 > 2^31.

**Evidence.** No validation of x_off/y_off/x_size/y_size against info$nx/info$ny before seek/readBin; idx built with integer multiplication.

**Suggested fix.** Check the window against info$nx/info$ny and abort like GDAL does. Build idx in double: (seq_len(y_size) - 1) * (nx * 4).

**Verifier.** .raw_vrt_read (L926-990) does no bounds checking before seek/readBin, and idx uses integer products (seq_len(y_size)-1L)*(nx*4L) that can overflow. Internal callers pass in-grid chunk windows, so this is reachable only through the exported gdal_read_window on a raw cube, or with very large partial-width windows.

### 85. .vrt destinations silently drop scale/offset and creation options
`R/gdal_adapter.R:1312` · gdal-io · api

**Problem.** gdal_create_output() returns .raw_cube_create() for a .vrt path before scale, offset and options are handled. A caller that passes scale/offset (documented as 'written on every band') gets a cube without them and no warning.

**Evidence.** if (grepl('\\.vrt$', path, ...)) return(.raw_cube_create(path, grid, n_bands, nodata, band_names)), scale/offset/options are not forwarded.

**Suggested fix.** Forward scale/offset into the VRT XML, and warn or abort when `options` is given for a .vrt destination.

**Verifier.** L1312-1314 returns .raw_cube_create(path, grid, n_bands, nodata, band_names) before options/scale/offset are used. write_tif rejects .vrt paths (write_tif.R:89), so the main public writer cannot hit this; the exposure is direct gdal_create_output calls.

### 86. Dead helper and stale route comments/docs
`R/gdal_adapter.R:1893` · gdal-io · dead-code

**Problem.** .gdal_log_errors_off() has no callers. In composite_direct.R L630-635 the comment says a single pool 'uses the simpler parallel-or-whole-grid path below', but only the whole-grid kernel follows, and the roxygen title calls it a 'no-focal composite' although morphology focals are replayed. gdal_mosaic_vrt docs (L1150) and the dataset.R:367 comment say non-mosaicable tiles are read by gdal_warp_vrt(), which takes exactly one source; gdal_warp_window() is the reader. The gdal_warp_to_buffer comment (L1466) cites a 'Remotes pin on the dev version', which contradicts the no-pin policy.

**Evidence.** grep finds .gdal_log_errors_off only at its definition; gdal_warp_vrt aborts with 'takes one source; several are read by gdal_warp_window()'.

**Suggested fix.** Delete .gdal_log_errors_off. Point the docs at gdal_warp_window(). Fix the route comments and the Remotes remark.

**Verifier.** .gdal_log_errors_off appears only at its definition (L1893). The composite_direct.R L630-633 comment describes a 'parallel-or-whole-grid path below', but only the whole-grid path follows. gdal_mosaic_vrt docs (L1150) point to gdal_warp_vrt, which rejects multiple sources (L1062-1064). The L1466 comment cites a Remotes pin.

### 87. cross_grid_window() is exported but unused by the package
`R/chunk_grid.R:186` · ir-planning · dead-code

**Problem.** The D5 'planning estimate' window mapper is exported and documented as part of planning, but no planner or executor code calls it; the only caller is a test. `.window_world_bounds` exists only to serve it. Exporting it commits the API, including its NA behaviour when `transform_bounds` fails, to a function the engine does not use.

**Evidence.** grep for `cross_grid_window(` in R/ returns only its definition; NAMESPACE line 53 exports it.

**Suggested fix.** Unexport it (mark @keywords internal) or remove it with its test.

**Verifier.** A grep shows cross_grid_window( only at its definition in R/, plus a test file (test-cross-grid-window.R). It is exported at NAMESPACE line 53 but unused by the engine.

### 88. graph_import does not remap SourceNode@collapsed ids
`R/graph.R:257` · ir-planning · bug

**Problem.** Only `@parents` is renumbered when a node is copied into `dst`. A collapsed multi-band SourceNode (created in place by `.collapse_band_stacks` on a user graph) carries `@collapsed` ids from the source graph. After import, plan_view's layer provenance (R/plan_view.R:219-220) resolves those ids against the destination graph and shows unrelated nodes.

**Evidence.** graph_import sets `node@id` and `node@parents` only (R/graph.R:257-258); `collapsed` is an integer node-id vector (R/node.R:120).

**Suggested fix.** Remap `@collapsed` through `id_map` when present, or drop it on import.

**Verifier.** graph_import (R/graph.R:256-258) remaps only @id and @parents. The only consumer of @collapsed is the plan_view provenance listing (R/plan_view.R:219-220), so after a cross-graph import it resolves stale ids. Display-only impact.

### 89. grid_equal ignores dim names, so t-stacks and band-stacks of equal length compare equal
`R/grid.R:413` · ir-planning · bug

**Problem.** `grid_equal()` compares dims by value and length only. A (x,y,t=3) grid equals a (x,y,band=3) grid, so `.lazy_binop` lets a time stack and a band stack combine elementwise. The result carries the left operand's axis name and labels, silently pairing slice i with band i.

**Evidence.** `all(a@dims == b@dims)` with no `names()` comparison (R/grid.R:417-418); `grid_diff` likewise returns 'grids are equal'.

**Suggested fix.** Compare `names(a@dims)` too, and report the difference in `grid_diff()`.

**Verifier.** grid_equal (R/grid.R:413-419) compares dims by length and value without names. Verified that grid_equal(t-stack grid, band-stack grid) is TRUE and st + sb builds a LazyRaster, pairing slice i with band i. This needs operands that are already mismatched, so low.

### 90. FocalNode docs list boundary policies that do not exist
`R/node.R:158` · ir-planning · docs

**Problem.** The exported FocalNode help says `boundary` is one of 'constant', 'reflect', 'nearest', 'wrap', 'none'. `focal()`, `focal_kernel()` and the dataset path accept only 'nodata' via `rlang::arg_match(boundary, 'nodata')`, and the evaluator implements only NaN padding. The validator also accepts any string when a FocalNode is built directly.

**Evidence.** R/node.R:158-160 versus R/lazy_raster.R:655 (`boundary <- rlang::arg_match(boundary, "nodata")`) and R/lazy_raster.R:1062.

**Suggested fix.** Document 'nodata' as the only policy and validate `boundary %in% 'nodata'` in the FocalNode validator.

**Verifier.** R/node.R:158-159 documents 'constant', 'reflect', 'nearest', 'wrap', 'none'. focal() and the dataset path use rlang::arg_match(boundary, 'nodata') (R/lazy_raster.R:650,655), and the validator does not check boundary. The docs are wrong, but users cannot reach the listed policies through focal(), so it is a docs-only defect.

### 91. Stale comment: band-stack collapse claims to skip sink stacks but does not
`R/passes.R:545` · ir-planning · docs

**Problem.** The header says 'Skips: stacks that are themselves requested sinks (sink retrieval from a coarse split read stage is not wired)'. The function never looks at `sink_ids` for that purpose, and later code (`read_px_of`, R/passes.R:1268-1279) explicitly handles collapsed stacks that are sinks. A maintainer reading the header would expect the wrong behaviour.

**Evidence.** `.collapse_band_stacks(graph, sink_ids)` uses sink_ids only to compute reachability (R/passes.R:556-558).

**Suggested fix.** Remove the stale sink-skip sentence from the header comment.

**Verifier.** The header comment at R/passes.R:545-546 says sink stacks are skipped, but the function body uses sink_ids only for reachability and has no sink exclusion. read_px_of (around R/passes.R:1268) explicitly handles collapsed source stages that are sinks.

### 92. garry_explain_placement(): empty table lacks the `tiles` column and docs omit it
`R/placement.R:331` · ir-planning · api

**Problem.** Non-empty decision tables carry a `tiles` column; the zero-row fallback does not. The @return docs list neither, so the return schema depends on whether any candidates exist, which breaks `rbind` across plans and any code selecting `tiles`.

**Evidence.** rows data.frame includes `tiles = tl$tiles` (R/placement.R:321); the empty data.frame (R/placement.R:331-341) has no `tiles`; the @return at R/placement.R:362-364 omits it.

**Suggested fix.** Add `tiles = integer(0)` to the empty table and document the column.

**Verifier.** Non-empty rows include tiles = tl$tiles (R/placement.R:321), but the zero-row data.frame (lines 331-341) lacks tiles. The @return docs (lines 362-364) omit tiles as well.

### 93. OCM default weights lookup and download are fragile
`R/ocm.R:30` · kernels · bug

**Problem.** .ocm_default_dir picks the 'newest' Python cache version by lexicographic sort of full paths, so '10.x' sorts below '9.x', and a newer non-v4 cache directory is chosen even when it lacks the v4 files that an older directory has. ocm_fetch_weights calls download.file under R's default options(timeout = 60), which is short for two ~29 MB files on slow links. It also ignores file.rename's return value.

**Evidence.** vers <- sort(list.dirs(base, recursive = FALSE), decreasing = TRUE); utils::download.file(..., mode = 'wb', quiet = quiet) with no timeout override; file.rename(tmp, dest) unchecked.

**Suggested fix.** Choose the directory that actually contains the v4 file names (or sort with numeric_version), raise the timeout locally with withr::local_options(timeout = max(600, getOption('timeout'))), and check the rename.

**Verifier.** In ocm.R:31, sort(list.dirs(...), decreasing = TRUE) is a lexicographic sort on full paths and does not check that the chosen directory holds the v4 files; a wrong pick fails later with a clear abort. In ocm_weights.R:333-350, download.file runs under the default 60 s timeout for ~29 MB files, and the return value of file.rename(tmp, dest) is ignored.

### 94. OCM weight cache can serve stale folds after a garry upgrade
`R/ocm_weights.R:382` · kernels · maintainability

**Problem.** The .rds cache key is the file hashes plus a hand-maintained version = 1L. A future change to .ocm_weights_regnety/.ocm_weights_edgenext, .ocm_eps or the BN-fold logic will silently load the old cached structure unless someone remembers to bump the constant. saveRDS writes in place, not atomically, so concurrent sessions can read a partial file and readRDS errors with no recovery. Separately, .ocm_fold_conv_bn ignores a conv bias that is present, although the header formula includes b[o]; this is harmless for the current weights, which have no such bias.

**Evidence.** hash <- rlang::hash(list(version = 1L, lapply(paths, rlang::hash_file))); if (file.exists(cache)) { out <- readRDS(cache); ... return(out) }; .ocm_fold_conv_bn returns b = b - mu * s, never reading a '<conv>.bias' key.

**Suggested fix.** Include utils::packageVersion('garry') in the key, write via a temp file plus file.rename, wrap readRDS in tryCatch and rebuild on failure, and fold a present conv bias (or assert its absence).

**Verifier.** The cache key is version = 1L plus the file hashes, so the fold logic is not keyed. saveRDS writes directly to the cache path, with no temp-and-rename. .ocm_fold_conv_bn reads only the BN tensors and drops any conv bias, although the header formula includes b[o]. The current weights carry no such bias, so this is maintainability only.

### 95. Exported ops whose pure-R oracle disagrees with or cannot run the traced path
`R/ops.R:366` · kernels · bug

**Problem.** The header says every op has an oracle with identical semantics, but several exported ops do not. (a) g_pad traced pads the last two dims of any rank (used on (t,y,x) cubes in composite_direct.R:53), while the oracle only handles matrices and errors on a cube. (b) g_stack's oracle fails on scalars (aperm on a non-array), while the traced path works. (c) g_cast(x, 'pred') maps NaN to NA in the oracle but to TRUE when traced. (d) g_round, g_clamp and g_quantize have no oracle at all.

**Evidence.** g_pad(array(1:24, c(2,3,4)), 1L, NaN) -> 'number of items to replace is not a multiple of replacement length'; g_stack(list(1,2)) -> 'invalid first argument, must be an array'; g_cast(c(NaN,0,2),'pred') = NA FALSE TRUE vs traced TRUE FALSE TRUE.

**Suggested fix.** Make the g_pad oracle pad the last two dims of any rank (as g_pad_rb's oracle already does), handle rank-0 in g_stack, map NaN to TRUE in the pred cast oracle, and add oracle branches or document traced-only ops.

**Verifier.** Checked in the code. The g_pad oracle builds a matrix from nrow/ncol only, while the traced path pads the last two dims of any rank. The g_stack oracle uses dim() on a scalar (NULL) and then aperm, which fails. The g_cast 'pred' oracle computes x != 0, which gives NA for NaN, while the traced convert gives TRUE. g_round and g_clamp call anvl directly with no oracle branch. All are exported.

### 96. Leftover capability gates and dead variable
`R/ops.R:485` · kernels · dead-code

**Problem.** Since anvl 0.5, .g_has_nv_scan() and .g_has_raw_upload() are both just is_installed('anvl'). They are exported dot-prefixed functions in the public NAMESPACE. .g_has_nv_scan has no caller in R/ apart from test skips, and the raw-upload gate's branches (composite_direct.R:268, 1034) can no longer fire, because .require_anvl already applies. In .ocm_infer, `sh4` is computed and never used (ocm_blocks.R:160).

**Evidence.** .g_has_nv_scan <- function() rlang::is_installed("anvl"); NAMESPACE export(.g_has_nv_scan), export(.g_has_raw_upload); ocm_blocks.R:160 sh4 <- ... unused.

**Suggested fix.** Remove the gates and their test skips before the stable release, or unexport them; drop sh4.

**Verifier.** Both gates are just is_installed('anvl') (ops.R:137, 485), and both are exported in NAMESPACE. .g_has_nv_scan has no caller in R/. The !.g_has_raw_upload() branches in composite_direct.R:268 and 1034 cannot fire once anvl is required. In ocm_blocks.R:160, sh4 is assigned and never used.

### 97. Kalman regime with no observations emits the previous regime's extrapolated level
`R/scan_kalman.R:182` · kernels · bug

**Problem.** At a boundary the forward pass resets P to the diffuse value but keeps the predicted mean a1p from the old regime. When the boundary year and every later year are missing, no update ever happens, and the output carries the old regime's level and slope forward as finite means. This contradicts the documented guarantee that 'nothing crosses a boundary in either direction'. The `ok` gate counts observations over the whole series, so it does not catch this. No test covers boundaries against a reference: tests check only traced/oracle parity and do not exercise boundaries at all.

**Evidence.** y = 100..106 then NaN x3, boundary at year 8. mean = 100..106, 107, 108, 109; sd = ..., 3162, 4472, 7071. Years 8-10 get a level extrapolated from the pre-boundary regime.

**Suggested fix.** Emit NaN for a year until its regime has at least one observation, e.g. track a per-pixel 'observed since last boundary' flag in the forward carry and mask m/s/z with it. Add a boundary test against KFAS fitted per regime segment.

**Verifier.** scan_kalman.R:180-187 resets only the covariances at a boundary; a1p/a2p carry the old regime forward. With no observations after the boundary, the emitted mean is the old regime's extrapolation, and ok (line 148) is computed over the whole series. This contradicts the doc line 78 ('nothing crosses a boundary in either direction'). The sd is huge (diffuse), so the result is flagged statistically, and the scenario (no observations after a boundary) is an edge case. Downgraded to low.

### 98. kalman_smooth(LazyDataset, obs_var = ...) fails with an unrelated class error
`R/scan_kalman.R:423` · kernels · api

**Problem.** The docs say x may be a LazyDataset, but with obs_var or boundaries set the target becomes list(x, obs_var). scan_over then treats it as a list of LazyRasters and .assert_class aborts on the dataset with a generic 'must be a LazyRaster' message. kalman_smooth also lacks the `bands` argument that hampel_smooth offers for datasets, an inconsistency between the two smoothers.

**Evidence.** target <- if (is.null(obs_var)) x else ... list(x, obs_var); scan_over(): xs <- if (is.list(x)) x; for (lr in xs) .assert_class(lr, LazyRaster, 'LazyRaster').

**Suggested fix.** Reject a LazyDataset combined with obs_var/boundaries with a clear message, or support per-band obs_var. Add `bands` for parity with hampel_smooth().

**Verifier.** kalman_smooth line 423 builds list(x, obs_var). scan_over (lazy_raster.R:954-959) only dispatches to .ds_scan when x itself is a LazyDataset; a list containing one hits .assert_class(LazyRaster). The docs say x may be a LazyDataset. kalman_smooth has no bands argument.

### 99. CI never tests the declared minimum R version
`.github/workflows/R-CMD-check.yaml:31` · package-docs · maintainability

**Problem.** DESCRIPTION declares Depends: R (>= 4.3). The oldest R in the check matrix is oldrel-1, which in October 2026 is 4.5, so the declared floor has never been exercised.

**Evidence.** The matrix covers macos release, windows release, ubuntu devel, ubuntu release and ubuntu oldrel-1. DESCRIPTION: Depends: R (>= 4.3).

**Suggested fix.** Add an ubuntu job on r: '4.3' (or oldrel-3), or raise the Depends floor to the oldest version CI covers.

**Verifier.** The matrix (R-CMD-check.yaml:27-31) has release, devel and oldrel-1 only; DESCRIPTION says R (>= 4.3), and no CI job tests that floor.

### 100. gdalraster floor is a dev version with an unpinned GitHub Remote, though CRAN 2.7.0 has the needed API
`DESCRIPTION:21` · package-docs · api

**Problem.** Imports declares gdalraster (>= 2.6.1.9001) and Remotes points at firelab/gdalraster HEAD. The comment in the CI workflow gives get_data_ptr() as the reason. gdalraster 2.7.0 is now on CRAN and its NEWS lists "add get_data_ptr()". As things stand, pak installs track gdalraster's moving dev HEAD, and all three workflows force-rebuild dev HEAD. A released garry is therefore never tested against the gdalraster users would get from CRAN. Remotes also pulls hypertidy/vaster from GitHub, although vaster is Suggests-only (used by one test) and 0.6.0 is on CRAN.

**Evidence.** available.packages() shows gdalraster 2.7.0 on CRAN. The installed gdalraster NEWS.md, under "# gdalraster 2.7.0", has "add `get_data_ptr()`". R-CMD-check.yaml step "Rebuild dev gdalraster from source" runs remotes::install_github('firelab/gdalraster', force = TRUE).

**Suggested fix.** Set gdalraster (>= 2.7.0), drop firelab/gdalraster and hypertidy/vaster from Remotes, and remove or narrow the forced dev-gdalraster rebuild in CI so CI tests what users install.

**Verifier.** Imports declares gdalraster (>= 2.6.1.9001) and Remotes includes firelab/gdalraster and hypertidy/vaster. CRAN has gdalraster 2.7.0 and vaster 0.6.0, and all three workflows force install_github for gdalraster. However, CRAN 2.7.0 already satisfies the floor, so users installing from CRAN are not blocked. The real issue is a CI and Remotes hygiene gap, so I downgraded it.

### 101. Grid-mismatch error suggests an align() signature that does not exist
`R/lazy_raster.R:437` · package-docs · docs

**Problem.** When grids differ, binary operators error with "use `align(a, b, to = ...)` first". align() is align(x, to, resampling), so the suggested call is invalid. This message appears verbatim in the prerendered getting-started vignette (vignettes/garry.Rmd:161-163). Its call frame also points at the internal .lazy_binop().

**Evidence.** cli::cli_abort(paste0("grids differ (...); ", "use {.code align(a, b, to = ...)} first")). The vignette output reads: Error in `.lazy_binop()`: ! grids differ (...); use `align(a, b, to = ...)` first.

**Suggested fix.** Suggest `align(x, to = <grid>, resampling = ...)` and pass call = rlang::caller_env() so the error reports the user's operator call.

**Verifier.** R/lazy_raster.R:433-437 suggests align(a, b, to = ...), but the actual signature is align(x, to, resampling), so the suggested call is invalid.

### 102. align() and lazy_source() accept any resampling string; bad values fail only inside GDAL at collect()
`R/lazy_raster.R:1102` · package-docs · api

**Problem.** lazy_dataset() validates resampling against a known list (R/dataset.R:235-256). align() and lazy_source() pass the string straight into the WarpNode or read spec. A typo surfaces only at execution, possibly after remote reads, as a raw GDAL error that does not name the argument.

**Evidence.** align(r, g, resampling = "bogus") builds without error. collect() then fails with "GDAL FAILURE 1: Unknown resampling method" and "warp raster failed (could not create options struct)".

**Suggested fix.** Validate resampling in align() and lazy_source() with the same .valid_resampling list lazy_dataset() uses, ideally through one shared helper.

**Verifier.** align (R/lazy_raster.R:1102-1119) stores resampling into WarpNode with no validation. The WarpNode property is a bare class_character, and lazy_source passes as.character(resampling) through. The failure is deferred to GDAL at collect time, which is a usability problem rather than wrong results.

### 103. Capability probes and anvl guards are dead code because anvl is a hard Import
`R/ops.R:137` · package-docs · dead-code

**Problem.** .g_has_raw_upload() and .g_has_nv_scan() return rlang::is_installed("anvl"), and .require_anvl() (R/ops.R:28, called 9 times) aborts when anvl is missing. anvl is in Imports, so these are always TRUE (or never fire). The fallback branches they gate (composite_direct.R:268 and :1034) and the test skips are unreachable. .g_has_nv_scan and .g_has_raw_upload are also exported, which adds two more pieces of public surface.

**Evidence.** R/ops.R:137-139: .g_has_raw_upload <- function() { rlang::is_installed("anvl") }. R/ops.R:485-487 is the same for .g_has_nv_scan. DESCRIPTION Imports: anvl (>= 0.5.1). Skips such as tests/testthat/test-scan-kalman-kfas.R:115 skip_if(!garry::.g_has_nv_scan(), ...).

**Suggested fix.** Remove the probes, .require_anvl and their gated branches and skips, and drop the two exports.

**Verifier.** R/ops.R:137-139 and :485-487 return rlang::is_installed("anvl"), and anvl (>= 0.5.1) is in Imports. The fallback branches at composite_direct.R:268/1034 and the .require_anvl abort are therefore unreachable. Both probes are exported in NAMESPACE.

### 104. Exported functions with no test reference, and no test pinning the documented reduce ops
`tests/testthat:1` · package-docs · test-gap

**Problem.** Several exported functions are never referenced in tests/testthat: stac_gti_index, garry_gdal_config, g_bitnot, g_concat_t, g_slice_t, g_expand, g_squeeze1, g_broadcast_arrays, g_round and g_clamp. Some may be covered indirectly, but there is no direct check of their contracts. Most significant is the absence of any test iterating the documented reduce_over() op list through collect(), which let six documented ops ship non-executable.

**Evidence.** A grep of every export name over tests/testthat/*.R finds none of the names listed above (besides the dot-prefixed daemon internals and some IR classes).

**Suggested fix.** Add a parametrised test over reduce_over's documented ops, plus direct oracle-versus-traced tests for the g_* shape ops and a stac_gti_index round-trip on local fixtures.

**Verifier.** A grep of tests/testthat finds zero references to stac_gti_index, garry_gdal_config, g_bitnot, g_concat_t, g_slice_t, g_expand, g_squeeze1, g_broadcast_arrays, g_round and g_clamp. No test iterates over reduce ops such as prod/sd/quantile through reduce_over; the only 'sd' hits are Kalman outputs.

### 105. Integer option validator throws an unclassed base error for large values
`R/options.R:31` · scheduler-pools · bug

**Problem.** For int = TRUE options, v != as.integer(v) yields NA (plus a coercion warning) when v is outside the integer range, and if (NA) raises 'missing value where TRUE/FALSE needed'. That is a plain simpleError instead of the garry_option_error naming the option, so the registry's promise of a clear, classed error does not hold here.

**Evidence.** options(garry.window_margin = 1e10); .garry_opt_check() raised a simpleError plus the warning 'NAs introduced by coercion to integer range'.

**Suggested fix.** Test with v != round(v), or check the range before coercing (abs(v) <= .Machine$integer.max).

**Verifier.** I reproduced it: with options(garry.window_margin = 1e10), .garry_opt_check() raises an unclassed simpleError ('missing value where TRUE/FALSE needed') plus a coercion warning from `if (int && v != as.integer(v))` in options.R. It does not raise garry_option_error.

### 106. Mixed routed scan shaping leaves the scan daemons on half-machine masks for all later plans
`R/pools.R:405` · scheduler-pools · bug

**Problem.** For a routed scan plan (0 < n_scan < pool width), .comp_pool_shape applies k_fat masks to the first n_scan pids and k_narrow masks to the rest, then records comp_threads <- k_narrow. For the next non-scan plan, k_want = max(2, cores %/% n_comp) equals k_narrow, so the identical() early return fires. The designated scan daemons keep their overlapping half-machine masks indefinitely, and placement is told every compute daemon has k_narrow threads. Only a fat-only plan or a new garry_daemons() call resets them.

**Evidence.** Mixed branch: k_narrow <- max(2L, cores %/% max(1L, length(pids))); ... .garry_state$comp_threads <- got (narrow). Uniform branch: k_want <- max(2L, cores %/% max(1L, n_comp)); if (identical(.garry_state$comp_threads, k_want)) return(invisible(NULL)).

**Suggested fix.** Record a mixed state, e.g. comp_threads plus a comp_shape tag ('mixed' / n_scan), and only short-circuit when the full shape matches. Alternatively, always re-apply masks when the previous shape was mixed.

**Verifier.** In the mixed branch (pools.R:380-398), the scan pids get k_fat masks and comp_threads is set to k_narrow, which equals cores %/% length(pids). For a later non-scan plan, k_want = cores %/% n_comp is the same value, so the identical() early return at pools.R:404 skips reshaping and the scan daemons keep half-machine masks. This only affects CPU affinity, which is a performance and cost-model accuracy issue, not correctness, so I downgraded it to low.

### 107. garry_daemons docs claim every daemon gets a disjoint CPU slice; read and compute masks overlap
`R/pools.R:422` · scheduler-pools · docs

**Problem.** The docs say 'Every daemon is pinned to a disjoint slice of the machine'. Masks are computed independently per pool, though, and both start at CPU 0, so compute daemons share CPUs with readers. With the default read = all logical cores, k = max(2, cores %/% cores) = 2, so every CPU is in two readers' masks (reader i and reader i + cores/2 get identical masks). reader_threads = 2 is also recorded for the placement cost model, which overstates per-reader throughput.

**Evidence.** lo <- ((i - 1L) * k) %% cores; cpus <- seq(lo, lo + k - 1L) %% cores, applied separately to 'garry_read' and to the compute pids. read defaults to cr$logical.

**Suggested fix.** Reword the docs to 'bounded, interleaved (not exclusive) CPU masks'. Or offset the compute masks and record the effective per-daemon share for the cost model.

**Verifier.** .pool_affinity_apply computes masks from CPU 0 for each pool independently (pools.R:345-346). Read and compute masks therefore overlap, and with read = logical cores, k = 2 and readers overlap each other. This contradicts the 'disjoint slice of the machine' wording in the garry_daemons docs (pools.R:422).

### 108. garry_daemons() does not validate read/compute/read_handles, and '...' conflicts with the hard-coded dispatcher
`R/pools.R:548` · scheduler-pools · api

**Problem.** read and compute are used directly. NA errors at 'if (compute > 0L)' with a base 'missing value' message. A negative compute silently creates no compute pool. A fractional value is truncated by seq_len(). read_handles = 0 (or garry.read_handles = 0, which bypasses .garry_opt_check because garry_daemons never calls it) gives a zero-depth handle cache. The '...' args go to all three mirai::daemons() calls, but the compute call already fixes dispatcher = FALSE, so passing dispatcher (or dispatcher-only args such as memory) errors or misbehaves. For a stable release, the public pool constructor should check its inputs.

**Evidence.** if (compute > 0L) { profs <- .glue('garry_comp_{seq_len(compute)}'); for (p in profs) mirai::daemons(1L, dispatcher = FALSE, .compute = p, ...) }; read_handles <- as.integer(read_handles %||% garry_opt('read_handles')).

**Suggested fix.** Validate read/compute as single non-negative whole numbers and read_handles as >= 1, using cli_abort with the argument name. Call .garry_opt_check() at entry. Document or filter which '...' args reach which pool.

**Verifier.** garry_daemons (pools.R:476-510) never validates read, compute or read_handles, and never calls .garry_opt_check. Passing dispatcher= through ... collides with the hard-coded dispatcher = FALSE in the compute daemons() call and fails with a 'matched by multiple actual arguments' error. As described.

### 109. Compute task working-set estimate is not clipped to the grid, unlike the store and warm-up estimates
`R/scheduler.R:964` · scheduler-pools · bug

**Problem.** The chunk dim is not capped at the grid size (.plan_chunk_dim is grid-agnostic: about 1000x1000 by default, or the whole RAM budget for patch stages), so chunk_dim can exceed the grid. store_mb (.store_region_mb uses pmin), the fetch-assemble estimate and the warm-up shapes (min(cd, dims)) all clip, but task_mb uses prod(cd + 2*need) unclipped. On small grids, compute tasks are over-priced by up to the chunk/grid area ratio. task_mb_max then inflates the compute floor and can trigger the spurious 'a single compute chunk is estimated at ... it will run one at a time' warning.

**Evidence.** task_mb <- .stage_bytes_per_px(...) * prod(as.numeric(cd) + 2 * need) / 2^20, versus .store_region_mb: pmin(as.numeric(chunk_dim), as.numeric(grid_dims[c('x','y')])) + 2 * pad.

**Suggested fix.** Use pmin(as.numeric(cd), as.numeric(s@grid@dims[c('x','y')])) in the task_mb product, as the other estimators do.

**Verifier.** scheduler.R:963-965 uses prod(cd + 2*need) without clipping to the grid. .chunk_for (passes.R:1692-1740) does not clip compute-stage chunk_dim to the grid, while .store_region_mb clips with pmin. On small grids compute tasks are therefore over-priced. Only admission conservativeness and a possible spurious warning are affected.

### 110. garry_task_report crashes on a log with no completed tasks
`R/task_report.R:74` · scheduler-pools · bug

**Problem.** When the log has no launch/done pairs (a header-only file, or a run that aborted before any task finished), split(tasks, tasks$stage) is empty, do.call(rbind, list()) returns NULL, and stages[order(stages$stage), , drop = FALSE] errors with an unhelpful base-R message. These are the cases where a user most wants the report.

**Evidence.** I ran garry_task_report() on a header-only CSV and got the error 'argument 1 is not a vector'.

**Suggested fix.** Guard with if (is.null(stages)) stages <- data.frame(stage = character(), pool = character(), n = integer(), ...), and return the rest of the summary.

**Verifier.** I reproduced it: garry_task_report() on a header-only CSV fails with 'Error in order(stages$stage) : argument 1 is not a vector' (task_report.R:74), a bare base-R error.

### 111. 'peak fleet anon RSS' in the task report is effectively a single-daemon peak
`R/task_report.R:105` · scheduler-pools · bug

**Problem.** The scheduler logs one rss row per daemon pid, and each log_line call stamps its own Sys.time() to the millisecond. The report sums RSS grouped by the exact time value, so rows from one sampling sweep only sum when they land in the same millisecond. With a fleet of 20+ daemons, most groups contain one or a few daemons, and peak_rss_mb (printed as 'peak fleet anon RSS') badly under-reports the fleet total. That makes the model-vs-measurement comparison the log exists for misleading.

**Evidence.** scheduler.R:2233-2236: for (p in .garry_state$pool_pids) { a <- .garry_anon_mb_of(p); ... log_line('rss', ...) }, with log_line formatting Sys.time() per call. task_report.R:105-109: split(as.numeric(rss$mb), rss$time) then sum.

**Suggested fix.** Capture one timestamp per sweep and pass it to every rss row (add a time argument to log_line), or log a sweep id. Alternatively, have the report group rss rows by the preceding 'model' row.

**Verifier.** scheduler.R:2233-2236 writes one rss row per pid, each stamped with Sys.time() at millisecond resolution. task_report.R:105-109 sums RSS grouped by the exact time string. Rows from one sweep spread over several milliseconds therefore land in separate groups, and the reported 'peak fleet anon RSS' under-counts. This only affects a diagnostic summary, so I rate it low.

### 112. plan_view() tooltips embed raw source paths, including SAS tokens, unescaped in HTML
`R/plan_view.R:248` · stac-views · bug

**Problem.** Source tooltips show basename(n@path). For a signed /vsicurl source (lazy_dataset file form with MPC hrefs) that basename includes the full ?sv=...&se=...&sig=... query, so a saved or shared widget exposes the token. Paths and band names are inserted into the HTML `title` without escaping, so `&` or `<` in a name corrupts the tooltip markup.

**Evidence.** `.glue("asset: {n@name} · {paste(basename(n@path), collapse = ', ')}")`, inserted into the title HTML at lines 504-516.

**Suggested fix.** Strip query strings before display (sub("\\?.*$", "", ...)) and pass the user-derived strings through htmltools::htmlEscape().

**Verifier.** plan_view.R:248 interpolates basename(n@path) and n@name into an HTML title without escaping. A /vsicurl signed href keeps its ?...sig= query in the basename. GTI-backed STAC datasets show only the index file, which limits the exposure.

### 113. preview() rejects 4D collected arrays with an opaque error and silently shows a time stack as RGB
`R/preview.R:250` · stac-views · bug

**Problem.** .plot_array() assumes 2D or 3D input. A 4D collect() result (band x t) gives nb_avail = 1, band1() returns the whole 4D array, and matrix() fails with 'data length differs from size of matrix'. A (y, x, t) array from lazy_stac_stack() is rendered as an RGB composite of the first three dates without notice.

**Evidence.** preview(array(runif(24), c(3,2,2,2))) fails with "data length differs from size of matrix: [24 != 3 x 2]".

**Suggested fix.** Abort with a cli message for arrays of rank above 3, asking the user to select or reduce first. Consider using the gis/labels to tell t apart from band.

**Verifier.** For 4D input, .plot_array treats nb_avail as 1 and passes the whole array to the band raster. In my run it did not error, contrary to the report: it warned 'data length differs' and rendered garbage. The (y,x,t)-as-RGB behaviour follows from the code.

### 114. preview() swallows misspelled arguments through `...`
`R/preview.R:582` · stac-views · api

**Problem.** preview() is not a generic, and `...` is documented as 'Unused'. A typo such as `strech = c(5, 95)` or `max_pixels = 500` is ignored silently and the defaults apply. This is cheap to fix before the API is frozen.

**Evidence.** `preview <- function(x, ..., na_col = NULL, ...)`: `...` is never used, and there is no rlang::check_dots_empty().

**Suggested fix.** Remove `...`, or call rlang::check_dots_empty().

**Verifier.** preview() is a plain function with `...` documented as Unused and no check_dots_empty, so misspelled arguments are swallowed.

### 115. stac_query() falls back to POST on any GET error, hiding the real failure; docs promise lubridate parsing
`R/stac.R:65` · stac-views · api

**Problem.** tryCatch(get_request) retries with POST on every error, including DNS, timeout, 5xx and 4xx parameter errors, not only when the API rejects GET. If POST also fails, the user sees the POST error and the original cause is lost. Nothing is retried on a transient 429 or 5xx. The docs also say the dates may be in 'any lubridate-parseable form', but the code uses as.POSIXct, which rejects forms such as "2023-01" or "01/02/2023". The bbox is also not validated with .check_bbox.

**Evidence.** `res <- tryCatch(rstac::get_request(search), error = function(e) { rstac::post_request(search) })`. Roxygen line 37: "Dates (any lubridate-parseable form)".

**Suggested fix.** Fall back to POST only on HTTP 405/400-method responses, chain the GET error as the parent of any final error, and validate bbox and dates up front. Correct the date wording in the docs.

**Verifier.** tryCatch at stac.R:65 falls back to POST on any error and discards the GET error. The roxygen promises lubridate parsing, but the code uses as.POSIXct. The bbox is not validated.

### 116. Re-signing an href strips any non-SAS query parameters
`R/stac.R:124` · stac-views · bug

**Problem.** .sign_href() and .mpc_resign() (line 187) drop the entire query string when they find an existing `sig=`, so parameters the href carried before signing are lost on re-sign. The comment says other queries are 'extended with &', but that holds only on the first sign.

**Evidence.** .sign_href("https://x/a.tif?foo=1&sig=old&se=x", "se=new&sig=new") gives "https://x/a.tif?se=new&sig=new" (foo=1 lost).

**Suggested fix.** Remove only the SAS keys (sv, se, sp, sig, st, sr, skoid, ...) and keep the other parameters.

**Verifier.** Reproduced: .sign_href('https://x/a.tif?foo=1&sig=old&se=x', ...) returns 'https://x/a.tif?se=new&sig=new'. MPC hrefs rarely carry other params.

### 117. MPC token cache: no retry on the token request and non-atomic writes to a file shared by daemons
`R/stac.R:215` · stac-views · bug

**Problem.** .mpc_token() performs a single httr2 request with no req_retry, so one 429 from the endpoint the docs warn about aborts stac_sign_mpc(). The token is written with saveRDS straight to a path shared by all daemons. When .mpc_resign fires on several daemons at once, they all miss the cache and write the same file concurrently, and a reader can hit a truncated RDS. In .mpc_resign that error is swallowed and the stale URL is used; in stac_sign_mpc it aborts.

**Evidence.** `tok <- httr2::resp_body_json(httr2::req_perform(req)); ...; saveRDS(tok, .mpc_token_file(collection))`; readRDS(f) in .mpc_token_lookup has no error handling.

**Suggested fix.** Add httr2::req_retry (honouring Retry-After), write to a temp file in the same directory and file.rename() it into place, and wrap readRDS in tryCatch so a corrupt entry counts as a cache miss.

**Verifier.** .mpc_token runs a single req_perform with no retry and saveRDS straight to the shared cache path. readRDS in lookup has no error handling. The concurrency window is narrow, so low severity is fair.

### 118. stac_sources() crashes with a cryptic error when no item carries the requested assets
`R/stac.R:330` · stac-views · bug

**Problem.** When `assets` matches nothing (a typo, or the wrong collection), every row is NULL, do.call(rbind, ...) returns NULL, and indexing NULL produces an internal error rather than a useful message. stac_filter_assets() warns about missing assets; stac_sources() does not.

**Evidence.** stac_sources(items, assets = "B99") gives the error "argument 1 is not a vector".

**Suggested fix.** After rbind, check is.null(out) and abort with a cli message that names the requested and available assets.

**Verifier.** Reproduced: stac_sources(..., assets='B99') fails with 'argument 1 is not a vector' from order() on a NULL rbind.

### 119. lazy_stac_stack() is a second exported STAC entry point that lags behind lazy_dataset()
`R/stac.R:781` · stac-views · api

**Problem.** lazy_stac_stack() duplicates lazy_dataset()'s STAC loop (dataset.R:319-346) but has no `resampling` argument, so it always reads with nearest. It returns a bare list(stack, slices, index) rather than a dataset object, and nothing in the package or vignettes calls it. Freezing it in v0.1.0 commits the project to maintaining two divergent constructors.

**Evidence.** grep finds no callers of lazy_stac_stack outside R/stac.R and its tests. lazy_dataset() passes `resampling = rs` to lazy_source(); lazy_stac_stack() does not.

**Suggested fix.** Unexport it or mark it superseded in favour of lazy_dataset(), or reimplement it as a thin wrapper over lazy_dataset() so the two cannot drift.

**Verifier.** The lazy_stac_stack signature has no resampling argument and returns a bare list. Its only references outside R/stac.R are tests and generated graph HTML.

### 120. as_dataset / lazy_map give opaque errors on non-LazyRaster input and skip grid checks across bands
`R/dataset.R:507` · user-api · api

**Problem.** as_dataset does not check that entries are LazyRasters (a numeric entry fails with "no applicable method for `@`") or that bands share a spatial grid. .ds_grid then reports the first band's grid in print/draw, and mismatches surface only at stack_bands. lazy_map(5, fn = ...) similarly fails at xs[[1L]]@graph (lazy_raster.R:233) before its friendly per-input check runs.

**Evidence.** lazy_map(5, fn = identity) -> "no applicable method for `@` applied to an object of class \"numeric\"" (verified).

**Suggested fix.** Run the class check before touching @graph in lazy_map. In as_dataset, assert LazyRaster entries and .spatial_equal grids with a cli error naming the band.

**Verifier.** Reproduced: lazy_map(5, fn=identity) gives 'no applicable method for `@`'. as_dataset has no LazyRaster or grid check on its entries.

### 121. group_by_time docs say collect() writes per-group files via `path`, but collect has no path argument
`R/dataset.R:821` · user-api · docs

**Problem.** The @return says collect() 'writes one file per group when `path` carries a `{group}` placeholder'. collect(x, plan_only, distributed) has no path argument; the {group} placeholder belongs to write_tif()/materialise(). Following the docs gives 'unused argument (path = ...)'.

**Evidence.** collect <- function(x, plan_only = FALSE, distributed = garry_daemons_set()) (R/collect.R:32); collect(x, path = out) errors "unused argument" (verified).

**Suggested fix.** Point the doc at write_tif(x, "ndvi_{group}.tif").

**Verifier.** collect's signature is (x, plan_only, distributed), with no path argument, yet the group_by_time @return text (dataset.R:819-822) says collect writes per-group files via path.

### 122. fill_gaps on a LazyDataset errors when any value band has a single slice
`R/dataset.R:884` · user-api · bug

**Problem.** For a length-1 band, fill_gaps uses the bare 2D layer instead of stacking it to t = 1 (unlike .ds_reduce and .ds_scan, which always stack). scan_over(over = "t") then aborts. Any dataset with a reduced or single-date band, including every file-form dataset, cannot be gap-filled.

**Evidence.** fill_gaps(as_dataset(list(a = x))) -> "`over` must name one dim of the input grid" (verified).

**Suggested fix.** Always lazy_stack(..., along = "t") as .ds_scan does, or skip single-slice bands.

**Verifier.** Reproduced: fill_gaps(as_dataset(list(a=x))) errors '`over` must name one dim of the input grid' because a length-1 band is not stacked to t=1.

### 123. qa_bits double-counts repeated bits, producing the wrong bitmask
`R/dataset.R:1188` · user-api · bug

**Problem.** The mask is built as sum(2^bits), so a repeated bit carries into the next one: qa_bits(c(1, 1)) tests bit 2, not bit 1. This happens easily when bit sets are concatenated (c(cloud_bits, shadow_bits) with overlap). Bit 31 overflows as.integer to NA with a warning. The display label (via .rng(unique)) still says 'bits 1', so the error is invisible in draw().

**Evidence.** m <- as.integer(sum(2^as.integer(bits))); attr(qa_bits(c(1,1)), "garry_desc") is "bits 1" while m = 4.

**Suggested fix.** Use unique(bits), validate 0 <= bits <= 30, and build the mask with Reduce(bitwOr, bitwShiftL(1L, bits)).

**Verifier.** m <- as.integer(sum(2^as.integer(bits))) has no unique(), so c(1,1) gives 4 (bit 2), and bit 31 overflows to NA. Requires repeated or high bits, so rated low.

### 124. draw() on a LazyRaster is exponential in shared subgraphs
`R/draw.R:144` · user-api · performance

**Problem.** .ir_tree recurses into every parent with no memoisation, so a DAG with reuse (x <- x + x, iterative smoothers, a mask shared across bands, fill_gaps linear's five uses of x) is expanded as a tree before .collapse_children folds it. Time doubles per level of reuse; a 37-node graph already takes about 7 s, and about 20 levels would take hours. print() is fine, but draw() is advertised in every print hint.

**Evidence.** y <- x; for (i in 1:n) y <- y + y; draw(y) takes 0.43 s at n=10, 1.65 s at n=12 and 6.7 s at n=14 (verified).

**Suggested fix.** Memoise subtree results (and signatures) by node id inside .ir_tree, and cap depth or node count with an elision marker.

**Verifier.** Reproduced: the y+y chain takes 0.15 s at 8 levels and 0.57 s at 10, so time roughly doubles per level. Deep reuse chains are uncommon in real pipelines and print() is unaffected, so downgraded to low.

### 125. time_sel/band_sel silently ignore prefix selectors when any exact label matches
`R/lazy_raster.R:370` · user-api · bug

**Problem.** Prefix matching is used only if no exact label matches. With sel = c("2023-01-01", "2023-02"), only the exact January slice is returned and the February prefix is dropped without any message. The doc describes the two match kinds as alternatives, not as all-or-nothing. NA in an integer sel gives 'missing value where TRUE/FALSE needed' instead of a clear error.

**Evidence.** time_sel(stack of 2023-01-01, 2023-02-01, 2023-02-05, c("2023-01-01","2023-02")) returns the single bare January layer (labels list()) (verified); time_sel(s, c(1, NA)) errors "missing value where TRUE/FALSE needed".

**Suggested fix.** Match each selector separately (exact, else prefix) and union the results. Error on any selector that matches nothing and on NA positions.

**Verifier.** Code at lazy_raster.R:369-375 uses prefix matching only when no exact label matches. Reproduced: time_sel(s, c('2023-01-01','2023-02')) returns a single x,y layer and silently drops the February prefix.

### 126. round(x, digits)/signif with extra args build fine but fail at collect with a base error
`R/lazy_raster.R:597` · user-api · api

**Problem.** When dots are passed, .lazy_math calls the base function on the traced array. anvl has no digits support, so round(x, 1) constructs and then fails at collect with 'non-numeric argument to mathematical function', far from the call site. The comment at line 600 acknowledges the gap.

**Evidence.** collect(round(x/3, 1)) -> "non-numeric argument to mathematical function" (verified).

**Suggested fix.** Implement digits as g_round(v * 10^d) / 10^d, or abort at construction when extra args are given to generics that do not support them.

**Verifier.** Reproduced: collect(round(x/3, 1)) errors 'non-numeric argument to mathematical function'. The dots path calls the base function on the traced array.

### 127. focal() does not validate radius
`R/lazy_raster.R:662` · user-api · api

**Problem.** radius is passed through as.integer() unchecked. Negative, NA, vector or fractional radii (1.5 becomes 1 silently) build a FocalNode. shrink_footprint validates the same argument, so the two are inconsistent. mask()'s open/dilate (dataset.R:1066) are also unchecked: NA errors with 'missing value where TRUE/FALSE needed'.

**Evidence.** focal(x, fn = function(s) s[[1]], radius = -1) prints a LazyRaster with 'focal r=-1' (verified).

**Suggested fix.** Validate a single non-negative whole number in focal(), and validate open/dilate in mask(), with cli errors.

**Verifier.** Reproduced: focal(x, radius=-1) constructs without error. Radius has no validation, unlike shrink_footprint. This is input validation only.

## Refuted

- grid_from_src() on a raster snaps the origin to multiples of res, shifting the native grid (`R/grid_from.R:174`): Snapping to multiples of res is the documented behaviour. R/grid_from.R:128-129 says the raster grid 'is simply re-gridded to res (the extent is snapped out to whole multiples of res)', and the raster branch calls the same .grid_from_extent used for bboxes. The half-pixel shift for offset origins follows from that documented design. At most, the phrase 'preserving its geometry' is loose wording.
- AEF vignette writes its output into the user's working directory (`vignettes/aef-embeddings.Rmd.orig:164`): The write_tif call at vignettes/aef-embeddings.Rmd.orig:163-170 is in a chunk with eval = FALSE, so running or knitting the vignette never writes km-aef.tif. The stray repo-root files are named km-aef4.tif and composite_garry.tif (also present under benchmarks/), so they come from ad hoc runs, not this vignette.
