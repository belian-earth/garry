# Daemon task body: write one sink chunk window to an output file.

The streamed-sink write, moved OFF the host dispatch thread: the host
creates the output (geometry, bands, nodata) and ships only the mori
region NAME plus window coordinates; this body maps the region, extracts
the chunk, materialises/converts it and runs the GDAL write — so the
multi-GB conversion transients (f64 scan sinks cannot ride the raw f32
store) live in one lean process that is reaped per task, not on the
thread that launches and harvests every other task. One writer daemon
per session: GTiff is single-writer, and daemon-persistent open handles
amortise the opens.

## Usage

``` r
.daemon_write_chunk(
  path,
  x_off,
  y_off,
  val,
  skey,
  el,
  pad,
  dtype,
  nodata,
  n_chunks,
  scale = numeric(0),
  offset = numeric(0)
)
```

## Arguments

- path:

  Output file (already created by the host).

- x_off, y_off:

  Window offsets.

- val:

  Shared store value; `el` names the element for split coarse-read
  parts, else `skey` (the export node key) extracts.

- skey, el:

  Extraction keys.

- pad, dtype, nodata, n_chunks:

  As the host-side write path.

## Value

`TRUE`.

## Details

Internal (exported only so mirai daemons can address it via `::`).
