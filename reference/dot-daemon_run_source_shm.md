# Daemon task body: read one source window into shared memory.

Coarse reads share their per-compute-chunk parts as elements of one
shared list: consumers extract their element zero-copy. (Consumer-side
RANGE subsetting of a mapped matrix would materialise the whole window
per input, a large transient allocation, so the split happens
producer-side here too.) Internal; daemons reach it through
`asNamespace("garry")`.

## Usage

``` r
.daemon_run_source_shm(
  ra,
  cg,
  core,
  key,
  reg_key,
  parts = NULL,
  fuse = NULL,
  read_raw = FALSE
)
```

## Arguments

- ra:

  Read arguments (as `.stage_read_args()`).

- cg:

  `ChunkGrid`; `core` the chunk row; `key` the node key; `reg_key` the
  daemon registry slot pinning the region.

- parts:

  NULL for chunk-aligned reads (the buffer is shared whole under `key`),
  else per-compute-chunk windows (`r0`/`c0` 0-based offsets, `nr`/`nc`
  sizes, `elt` the element name).

- fuse:

  The fused kernel to run on the window, or NULL.

- read_raw:

  Read as a raw f32 payload?

## Value

The shared object (serialises as its region name).
