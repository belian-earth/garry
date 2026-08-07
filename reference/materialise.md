# Materialise a lazy object locally and stay lazy.

The checkpoint verb (dbplyr's `compute()` for rasters): execute the
current graph, write the results to local raw-BSQ cubes (`.vrt` +
`.bin`, the format any GDAL tool reads and garry re-reads ~9x faster
than tiled GeoTIFF), and return the SAME KIND of lazy object rebuilt
over the local files. Everything downstream continues unchanged; nothing
upstream (network reads, warps, masking, model inference) runs again.

## Usage

``` r
materialise(
  x,
  dir = NULL,
  name = "garry",
  nodata = NULL,
  overwrite = FALSE,
  distributed = garry_daemons_set()
)
```

## Arguments

- x:

  A `LazyDataset` or `LazyRaster`.

- dir:

  Directory for the cubes (created if missing); default: a unique
  session-temporary directory.

- name:

  File-name stem (default `"garry"`).

- nodata:

  Optional sentinel for the written files, as in
  [`collect()`](https://belian-earth.github.io/garry/reference/collect.md).

- overwrite:

  Replace existing files at the target paths?

- distributed:

  As in
  [`collect()`](https://belian-earth.github.io/garry/reference/collect.md).

## Value

A lazy object of the same class as `x`, reading the local cubes.

## Details

A `LazyDataset` writes one multiband cube per time slice through a
single multi-sink plan (all slices' reads drain together), carrying band
names, slice dates, and the `mask_asset` into the rebuilt dataset;
ragged bands (a band missing some slices) survive. A `LazyRaster` writes
one cube and reopens it, which is also the sanctioned route around the
v1 "cannot warp a computed raster" rule:
`align(materialise(x, dir), grid)`.

Files land at `dir/name-<slice>.vrt` (dataset) or `dir/name.vrt`
(raster). Existing files are refused unless `overwrite = TRUE`: the
graph may have changed since they were written, and silently reusing
stale pixels is the failure mode a checkpoint must not have.

`dir` defaults to a fresh unique directory under the session's
[`tempdir()`](https://rdrr.io/r/base/tempfile.html), announced by a
message: convenient, but session-scoped (the files vanish when R exits),
and every call writes a NEW copy, so repeated interactive re-runs
accumulate until the session ends. For large cubes, or to keep or reuse
a checkpoint, give a real directory (note some systems mount `/tmp` in
RAM).
