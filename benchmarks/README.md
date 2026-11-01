# garry benchmarks

Measures garry against the best Python option on synthetic rasters, under one memory cap, with every output checked. The Open Data Cube stack (odc-stac, Dask, numbagg) is the primary comparator; Cubed is a separate memory track. Older results and the reasoning behind them are in [`design/benchmark-history.md`](../design/benchmark-history.md).

## Engine contract

An engine is `engines/garry.R`, `engines/odc.py` or `engines/cubed.py`. A task is a named function in each, with its parameters from `spec/tasks.json`; there is no op interpreter. Defaults on both sides, no per-task tuning. `run.py` starts one fresh process per run:

    <engine> --task ID --size small|medium --variant aligned|warp|default --out DIR [--warm] [--arm NAME] [--chunk N] [--read-pool N]

- **Data.** Read `$GARRY_BENCH_DATA/<size>/manifest.json`. `root` is the absolute data folder. `datasets` has `hls-warp`, `hls-aligned`, `embed`, `annual` and `hls-zarr`, each with `grid` (`crs`, `xmin`, `ymin`, `xmax`, `ymax`, `nx`, `ny`, `res`), `files` and `digest`. An hls entry adds `items` (the path under `root` of a STAC ItemCollection with absolute hrefs), `bands`, `mask_band`, `nodata`, `mask_nodata`, `dates`, and `ids` with `item_t`; a file is `<dataset>/<id>/<id>.<band>.tif`. `annual` adds `years`, with `files` in year order. `hls-zarr` adds `store`: arrays named by band, `(t, y, x)`, whole-t chunks.
- **Arms and threads.** `--arm` is `odc-dask` or `odc-threads`. `--chunk` and `--read-pool` override, for a sweep, the odc-dask chunk and the odc-threads read pool in `spec/tasks.json`. `BENCH_THREADS` holds the thread count: pin Dask workers, `NUMBA_NUM_THREADS` and `GDAL_NUM_THREADS` to it. garry takes `garry_daemons()` defaults. No script may set a removed `garry.*` option.
- **Output.** Cold writes `DIR/cold.tif`, warm writes `DIR/warm.tif`. One plain GeoTIFF as `output` in `spec/tasks.json` says, which is `write_tif()`'s default: Float32, DEFLATE, 256 px tiles, band interleave, no overviews, digital numbers with no scale, NaN as nodata. A task's own `output` block overrides it. Bands follow the order in `params`.
- **Timing.** Start the clock after pools are up and `items.json` is parsed; stop it when the output is closed. `--warm` runs the task a second time in the same process.
- **stdout.** One JSON line per phase, `{"phase": "cold", "wall_s": 12.3, "startup_s": 2.1, "route": "composite_direct"}`, then `"warm"`. `startup_s` is process start to ready, pool start included, and repeats on the warm line. `route` is `garry_last_route()`, garry only. Other keys land in the record under `extra`; `jit_s` there is a one-off compile that stays in wall, and `report.py` footnotes it. Once per run, print `{"phase": "env", ...}` with GDAL and PROJ versions, thread settings and, for Python, the numba threading layer and proof that numbagg ran; garry adds `build`, the library, build time and a hash of the installed files. Other stdout is ignored, so logs may share it; errors go to stderr.
- **Failure.** Exit nonzero. Do not catch an error to print a time. A phase that printed its line keeps its wall: the failure goes to the first phase with no line, and any later phase reads `not_reached`.

The geomedian reference is one run of `run.py ref --size S --variant V`, which starts `engines/odc.py --task geomedian_ref --size S --variant V`: geomad with the task's `reference` tolerances, saved to `$GARRY_BENCH_DATA/<size>/ref/geomedian-<variant>.npz` as `cube` (band, t, n), `ref` (band, n), `rows` and `cols`, the pixels of a grid of step `objective_stride`. `check.py` then records each output's relative objective gap, and refuses a reference of other data. Run `ref` again after `gen --force` and after changing `arms.odc-dask.chunk`: a warp read moves with the chunk, on small by at most 0.03 DN from 2048 to 1024 and 120 DN from 2048 to 512, with 900 of 6.0 million sampled cells changing NaN pattern.

## Use

    cd benchmarks
    uv sync
    export GARRY_BENCH_DATA=/some/disk R_LIBS=/library/holding/the/garry/to/measure
    uv run python run.py gen --size small
    uv run python run.py gen --size small --datasets hls-zarr
    uv run python run.py ref --size small --variant aligned && uv run python run.py ref --size small --variant warp
    uv run python run.py bench --size small --reps 3
    uv run python report.py results/<date>-<sha>.jsonl

`Rscript` loads the first garry on its library path, and the commit in a record is the repository's HEAD, which that library need not hold. The env record names the library and a hash of the build, and `report.py` never pools rows across cap, commit, spec or build.

`gen` also takes `--force`. `hls-zarr` is Cubed's store, a second `gen` because it is built from `hls-aligned`; without it the cubed rows read `no_data`. `gen.py --size medium --estimate` prints the disk needed, and it refuses below twice that free. Medium hls is 13 GB at the compression seen on small, so generate one variant at a time when disk is short. `large` is defined and refused.

`bench` also takes `--tasks`, `--arms`, `--variants`, `--tag`, `--engine-args` and `--no-warm`. `--arm-cmd "NAME=CMD"` adds an arm, such as a garry from another library:

    uv run python run.py bench --arm-cmd "garry-old=env R_LIBS=/old/lib Rscript engines/garry.R" --arms garry,garry-old

## Sweeps

`spec/tasks.json` holds one odc-dask chunk per size and one odc-threads read pool, each swept once and its best kept. Medium has no chunk yet, because its data waits for the final run. `bench` refuses it, unless `--engine-args` passes a `--chunk`, until one is swept at that size on every task and variant:

    for pass in 1 2; do for c in 1024 2048 4096; do
      uv run python run.py bench --size medium --arms odc-dask --reps 1 --tag chunk=$c --engine-args "--chunk $c" --results sweep.jsonl
    done; done
    uv run python report.py sweep.jsonl

`report.py` prints each value's wall over the best value's per task, as a geometric mean. Keep the best under `arms.odc-dask.chunk.medium`, and say why below. `--tag read_pool=4 --engine-args "--read-pool 4"` sweeps the pool the same way.

## Measurement

Every run, `gen.py` and `check.py` included, is `timeout -k 10 L systemd-run --user --scope --collect -q -p MemoryMax=CAP -p MemorySwapMax=0 scope.sh ...`, at 8G for small and 16G for medium. `scope.sh` samples anon plus shmem every 0.2 s, the primary peak, and reads `memory.peak` and `memory.events` before exit. After a kernel kill systemd stops the scope with SIGTERM, so exit 143 usually means an OOM kill: `oom_kill` in the record settles it. `run.py` then unlinks what the dead run left in `/dev/shm` and records it as `shm_orphans`.

Cold means a new scope and new pools, with source pages dropped by `posix_fadvise` first; `cold_resident_mb` records what stayed. Warm is the second run in that process. Three repeats at least, engine order alternating, load average logged per run. Outputs are hashed and compared, then deleted. The check between engines reads the first cold output of each arm; a warm output must hash the same as its own cold, or the run reads `warm_differs`.

`results/<date>-<sha>.jsonl` holds one record per run and phase: task, size, variant, arm, commit, build, spec and data hashes, rep, phase, wall, startup, both peaks, cap, memory.max events, exit, oom_kill, route, output hash, load. `peak_anon_shmem_mb` is that phase's own, split by the sampler's clock; `memory_peak_mb` covers the whole run and cannot be split. A failed arm is a result: `report.py` lists failures first. Its peak column reads `>=` when the cap cut a peak short, and its ratio `n/c` when two geomedians are not at equal convergence, which `gap` in `spec/tasks.json` defines. `run.py` exits 1 when garry's route differs from the spec.

## Data

`gen.py` is the only generator. Seeds derive from (dataset, tile, t, band), so order cannot change a pixel: smooth fields with clustered clouds and shadows, 72 % of pixels flagged by Fmask bits 0 to 3 and a median of 12 clear dates per pixel on small. `hls` is Int16 with nodata -9999 and UInt8 Fmask with nodata 255, in tiled DEFLATE GeoTIFFs. `warp` puts 98 items in UTM zones 54 and 55 onto the EPSG:20255 grid of the old reference workload; `aligned` puts 55 items on that grid, so the value check can be tight. `embed` is 64 Int8 bands, ZSTD, band interleave, 1024 px tiles. `annual` is 15 f32 files with NaN gaps, level breaks and outliers.

## Comparator decisions

Measured on this suite's small data on 2026-11-01, on a 20-thread workstation. Lines marked (probe) are short runs outside the cold protocol, some beside other work on the machine, so read them for direction.

| Choice | Kept | Evidence |
|---|---|---|
| Kalman library | simdkalman | 128^2 x 15, 18 % gaps, forced edge pixels, against an 80-bit reference. simdkalman takes NaN as a gap: 8e-8 at most, exact NaN pattern. dynamax 1.0.3 spreads NaN through 97 % of the values of eligible pixels, and reaches 1e-7 only through a hand-built time-varying emission variance. garry's f32 output is 1.9e-6 from the reference. Same Q, R and diffuse start; Q drives t to t+1 on both sides, and year one takes F(kappa I)F' + Q. |
| odc-dask chunk | 2048 at small, one block per slice. Medium unswept | Wall over the best value, 10 task variants, two passes, cold then warm: 512 1.60, 1.95; 1024 1.10, 1.18; 2048 1.00, 1.00. Warp gains as aligned does: median warm 9.6 to 7.4 s. |
| odc-threads read pool | 4, on every task | Median, ndvi and geomedian, two passes, cold then warm: 2 reads 1.10, 1.13; 4 1.00, 1.00; 8 1.05, 1.06; 20 1.15, 1.26. |
| ts_kalman on odc-dask | Reads on threads, kernel in processes, block side from the grid so tasks are at least 4 x workers, the threads arm's count | Wall fell from 4.6 to 2.6-3.3 s, against 2.0-2.5 s on the threads arm. |
| Dask scheduler | Threads, as the brief fixes | LocalCluster 5 x 4, best runs (probe). Warp warm: median 6.6 against 7.3 s, ndvi 4.5 against 5.8 s. Warp first run: 24 against 15 s, 23 against 14 s. Aligned warm: 5.1 against 3.0 s, 3.1 against 2.5 s. geomedian cannot run there: `yxbt_sink`'s token refuses to pickle. |
| geomad | The wheel | A `-march=native` rebuild of its C showed no consistent gain (probe): 0.145 against 0.150 s on f32 on a quiet machine, 0.23-0.26 against 0.25-0.33 s in alternating passes on a busy one. |
| rasterio | The wheel, GDAL 3.12.2 | A source build on the system's GDAL 3.13.3, which garry reads with: same median output on aligned, 6.1e-5 apart at most on warp, and fastest runs within 13 % with no consistent winner over 7 interleaved pairs (probe). |
| Median kernel | numbagg, as the brief fixes. **Open** | numbagg has one float64 loop that allocates per lane. A 20-line numba gufunc behind the same call, with identical output (probe): ts_hampel warm 5.9-6.7 to 0.70 s on odc-dask, 6.3-6.9 to 0.94-0.99 s on odc-threads; median aligned warm 3.6-3.7 to 2.7-3.0 s. Read the ts_hampel row as numbagg against garry. |
| Mask cleanup | `mask_cleanup` | What a skilled ODC user writes. Its distance transform takes 0.14 s a slice against 0.03 s for binary morphology with the same disks, with the same cells (probe). |
| Geomedian stop | eps 0.45 | Summed gap on small aligned: 1.69e-6 against 1.85e-6 at garry's 12 iterations. Untested on medium, so `report.py` prints `n/c` past a factor of 2. On warp the int16 read floors the gap at 5.3e-6 at any eps, where f32 input reaches 1.2e-10, so garry's warp ratio always reads `n/c`. |
| Compile | In wall on both sides | numba's compile of numbagg is 6-7 s once per process, recorded as `jit_s` and footnoted, so the cold column on small is not a data-size result. |

## Out of scope

No remote or latency tier: local data cannot show fetch width or range counts, so `design/benchmark-history.md` stays the record for those. No `predict` task from the audit's list.
