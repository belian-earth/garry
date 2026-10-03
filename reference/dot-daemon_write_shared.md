# Daemon task body: write prepared band planes to an output.

The write half of the read-only route's streamed write: maps the planes
[`.daemon_read_for_write()`](https://belian-earth.github.io/garry/reference/dot-daemon_read_for_write.md)
shared and writes plane `b` to band `band0 + b` of the output the host
created. Shares the writer's open-handle cache with
`.daemon_write_chunk`.

## Usage

``` r
.daemon_write_shared(path, x_off, y_off, w, band0)
```

## Arguments

- path:

  Output file (already created by the host).

- x_off, y_off:

  Window offsets.

- w:

  The read task's result: region name and window size.

- band0:

  Bands before this chunk's first.

## Value

`TRUE`.

## Details

Internal; daemons reach it through `asNamespace("garry")`.
