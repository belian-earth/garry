# A GDAL-readable source: path + band + optional nodata sentinel.

A declared `nodata` on an integer source promotes the source's output
dtype to f32 so NaN can carry nodata downstream (decision D8); the
executor rewrites `value == nodata` to NaN at read time.

## Usage

``` r
SourceNode(
  id = integer(0),
  parents = integer(0),
  grid = GridSpec(),
  path = character(0),
  band = integer(0),
  nodata = integer(0),
  block_dim = integer(0),
  open_options = character(0),
  resampling = "near",
  scale = numeric(0),
  offset = numeric(0)
)
```

## Arguments

- id:

  Integer node id (assigned by
  [`graph_add()`](https://belian-earth.github.io/garry/reference/graph_add.md)).

- parents:

  Integer ids of parent nodes (may be empty).

- grid:

  Output `GridSpec` of this node.

- path:

  Path or VSI URL readable by GDAL.

- band:

  1-based band index.

- nodata:

  Length-0 (absent) or length-1 nodata sentinel value.

- block_dim:

  Native GDAL block size (length 2), or length 0 if unknown; the
  chunking pass snaps chunk sizes to it.

- open_options:

  GDAL open options ("KEY=VALUE"), e.g. GTI FILTER.

- resampling:

  GDAL resampling used when a read reprojects/rescales the source onto
  the analysis grid (default "near").

- scale, offset:

  Length-0 (absent) or length-1 band affine applied inside the read
  kernel after sentinel -\> NaN (see
  [`lazy_source()`](https://belian-earth.github.io/garry/reference/lazy_source.md)).

## Value

A `SourceNode`.
