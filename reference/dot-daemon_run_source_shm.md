# Daemon task body: read one source window into shared memory.

The mori-store counterpart of `.daemon_run_source` and
`.daemon_run_source_split`. Coarse reads share their per-compute- chunk
parts as elements of one shared list: consumers extract their element
zero-copy. (Consumer-side RANGE subsetting of a mapped matrix would
materialise the whole window per input, a large transient allocation, so
the split happens producer-side here too.) Internal (exported only so
mirai daemons can address it via `::`).

## Usage

``` r
.daemon_run_source_shm(
  path,
  band,
  nodata,
  cg,
  core,
  key,
  reg_key,
  parts = NULL,
  open_options = character(0),
  fuse = NULL,
  read_raw = FALSE,
  store_raw = FALSE,
  scale = numeric(0),
  offset = numeric(0),
  decim = NULL
)
```

## Arguments

- path, band, nodata:

  Source identity.

- cg:

  `ChunkGrid`; `core` the chunk row; `key` the node key; `reg_key` the
  daemon registry slot pinning the region.

- parts:

  NULL for chunk-aligned reads (the buffer is shared whole under `key`),
  else per-compute-chunk windows (`r0`/`c0` 0-based offsets, `nr`/`nc`
  sizes, `elt` the element name).

- decim:

  Optional decimating-read spec (see
  [`gdal_read_window()`](https://belian-earth.github.io/garry/reference/gdal_read_window.md)),
  set when an aligned warp is served by a direct RasterIO read.

## Value

The shared object (serialises as its region name).
