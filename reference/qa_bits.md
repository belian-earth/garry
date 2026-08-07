# Build a QA-bitmask predicate.

Returns a predicate `\(f) ...` for
[`mask()`](https://belian-earth.github.io/garry/reference/mask.md)'s
`where` argument that flags a pixel bad when any of the given bits is
set. Nodata pixels are treated as clear (matching the QA-fill
convention). Use for packed-flag QA bands (HLS Fmask, Landsat QA_PIXEL)
where a value list cannot express the test; categorical bands
(Sentinel-2 SCL) use a plain value vector instead.

## Usage

``` r
qa_bits(bits)
```

## Arguments

- bits:

  Integer bit positions (0-based) that mark a pixel as bad.

## Value

A function of one traced array.
