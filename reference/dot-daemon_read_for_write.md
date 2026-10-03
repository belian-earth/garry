# Daemon task body: read a chunk and prepare its band writes.

The read half of the read-only route's streamed write, on the read pool:
reads the chunk as raw f32, turns each band plane into the vector GDAL
writes (nodata folded, the integer-output check made) and shares the
planes in one shared-memory region pinned under `reg`. The writer daemon
maps the region by name, so the payload never passes through the host
and the writer only writes.

## Usage

``` r
.daemon_read_for_write(ra, cg, core, dtype, nodata, reg)
```

## Arguments

- ra:

  Read arguments (as `.stage_read_args()`).

- cg, core:

  Chunk grid and chunk row.

- dtype, nodata:

  Output dtype and sentinel.

- reg:

  Registry key pinning the region until the host drops it.

## Value

list(name, reg, nr, nc, mb): the region name and registry key, the
window size and the region's size in MB.

## Details

Internal; daemons reach it through `asNamespace("garry")`.
