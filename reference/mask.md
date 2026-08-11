# Mask a dataset from a QA band.

Derive a bad-pixel mask from a named QA band, optionally clean it with
binary morphology, set bad pixels to NaN (nodata) on every value band,
and drop the QA band. The mask is a shared subgraph computed once per
slice and reused across all value bands.

## Usage

``` r
mask(
  x,
  from = NULL,
  where,
  open = 0L,
  dilate = 0L,
  drop = TRUE,
  join = "exact"
)
```

## Arguments

- x:

  A `LazyDataset`.

- from:

  QA band to derive the mask from; defaults to the dataset's
  `mask_asset`.

- where:

  The removal predicate (mask where TRUE). One of:

  - a numeric vector -\> value membership (bad if the pixel value is in
    the set), for categorical QA such as Sentinel-2 SCL, e.g.
    `c(0, 1, 2, 3, 8, 9, 10, 11)`;

  - [`qa_bits()`](https://belian-earth.github.io/garry/reference/qa_bits.md)
    -\> a bitmask test (bad if any listed bit is set), for packed flags
    such as HLS Fmask / Landsat QA_PIXEL, e.g. `qa_bits(0:3)`;

  - a function `\(f) ...` -\> a predicate returning a 0/1 (or logical)
    mask, written in the `g_*` vocabulary.

- open:

  Opening radius (despeckle): erosion then dilation at this radius,
  removing isolated flagged pixels up to the radius. `0` skips it.

- dilate:

  Dilation radius (buffer): grows the surviving bad regions outward, a
  safety margin around clouds. `0` skips it. Applied after `open`.

- drop:

  Drop the QA band from the returned dataset? (default `TRUE`.)

- join:

  How value and mask slices pair when both carry slice names that do not
  fully align: `"exact"` (default) aborts; `"inner"` pairs on the shared
  slice names and reports what dropped.

## Value

A `LazyDataset` with masked value bands.
