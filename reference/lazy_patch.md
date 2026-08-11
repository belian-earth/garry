# Whole-window model op (advanced): apply `fn` to the raw padded chunk.

The escape hatch behind model-inference verbs such as
[`ocm_mask()`](https://belian-earth.github.io/garry/reference/ocm.md):
where
[`focal()`](https://belian-earth.github.io/garry/reference/focal.md)
materialises a shift list (unusable beyond small radii), a patch op
hands `fn` the raw window carrying `radius` halo cells per side and
crops the contaminated ring off the result. `fn` must be size-preserving
on the last two (spatial) dims, derive every size from its input's
shape, be written in the `g_*` vocabulary, and reduce the leading band
axis to `out_bands` channels (0 = a plain 2D result). Not
differentiable.
[`ocm_model()`](https://belian-earth.github.io/garry/reference/ocm.md)-based
cloud-mask prediction is the in-package example of its use.

## Usage

``` r
lazy_patch(
  x,
  fn,
  radius,
  out_bands = 0L,
  dtype = "f32",
  kernel_id,
  bytes_px = 512,
  flops_px = 10000
)
```

## Arguments

- x:

  A `LazyRaster` (typically a `(band, y, x)` stack).

- fn:

  Model body `fn(xpad)`, size-preserving.

- radius:

  Halo consumed per side, pixels.

- out_bands:

  Output band count; 0 drops the band axis.

- dtype:

  Output dtype (default `"f32"`).

- kernel_id:

  Content identity of the closed-over model.

- bytes_px:

  Working-set estimate, bytes per core pixel.

- flops_px:

  Compute estimate, flops per core pixel.

## Value

A `LazyRaster` on the spatial grid (plus `out_bands` bands).

## Details

`kernel_id` stands in for `fn` in kernel signatures: give two calls the
same id ONLY if their fns are interchangeable (same weights, same code).
`bytes_px`/`flops_px` price the kernel for chunk sizing, memory
admission, and placement, which cannot introspect `fn`.
