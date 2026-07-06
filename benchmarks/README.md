# garry benchmarks

The reference workload is vrtility's median-composite benchmark
(`vrtility/benchmarks/`): HLS S30 from Planetary Computer over a PNG
bbox, all of 2023, Fmask bits 0-3 masked, warped to the EPSG:20255
30 m grid, temporal median, written to disk. The aim is parity with
Open Data Cube + dask; vrtility already beats it.

## Results (this machine, 2026-07-05)

| pipeline | bands | wall time |
|---|---|---|
| ODC + dask (Python) | 3 | 28.4 s |
| vrtility (15 daemons) | 3 | 20.7 s |
| garry (12 daemons) | 3 | 131.7 s |
| garry (12 daemons) | 1 | 46.7-48.5 s |

Numbers are network-sensitive: one throttled evening run took 1068 s
for the identical three-band workload, so compare runs from the same
sitting. garry is correct but not yet fast. Correctness: garry's B04
composite vs vrtility's agrees at correlation 0.992, mean abs diff
13.9 reflectance units; the residual is nearest-vs-bilinear tile
resampling and per-day-slice vs per-item stacking.

Known structural gaps, all planned (Phase 9):

1. **Mask stages materialise before stacking.** Each day's masked band
   round-trips device -> R -> chunk store -> R -> device between the
   mask stage and the stack stage. A planner stage-merge pass fuses
   mask -> stack -> median into a single XLA kernel per chunk and
   deletes ~110 store round-trips per band.
2. **Fmask is read once per band.** vrtility shares the mask across
   its three bands in one pass; garry currently rebuilds the mask
   stack per band. Multiband collect solves this.
3. **Serial tail.** With single-chunk execution the final 55-layer
   stack+median runs as one task on one daemon; 2-4 chunks would
   overlap it with reads at the cost of more requests.

## Running

```sh
Rscript benchmarks/hls-median-composite.R 12 B04           # one band
Rscript benchmarks/hls-median-composite.R 12 B04 B03 B02   # full workload
```

Network required (Planetary Computer, anonymous + pre-signed hrefs).
The STAC query is untimed, matching the reference benchmarks.

## What the script shows about the API

- `stac_query()` -> `stac_sources()`: search results become a flat
  table (one row per item x asset); `stac_drop_duplicates()` /
  `stac_time_slices()` are plain-R table operations.
- `stac_gti_index()`: the table becomes a GDAL GTI tile index; each
  day is a `FILTER`ed mosaic of that index, pinned to the target grid
  via open options (mixed UTM zones are reprojected per tile by GDAL).
- `lazy_map(band, fmask, dtype = "f32", fn = ...)`: elementwise ops
  written in plain R with the `g_*` vocabulary; they trace into fused
  XLA kernels (the Fmask bit test and NaN masking never touch an
  interpreter at execution time).
- `lazy_stack() |> reduce_over("median", "t", nan_rm = TRUE)`: the
  composite itself; NaN is nodata everywhere (D8).
- `collect(x, path =, distributed = TRUE)`: plan, execute across mirai
  daemons, stream chunks to GTiff.
