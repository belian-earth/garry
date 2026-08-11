# Elementwise map over one or more aligned rasters.

`fn` receives one traced array per input raster and returns one array;
it runs fused with adjacent operations in one compiled kernel. Write it
with plain arithmetic and the `g_*` vocabulary
([`g_ifelse()`](https://belian-earth.github.io/garry/reference/g_ifelse.md),
[`g_bitand()`](https://belian-earth.github.io/garry/reference/g-bitwise.md),
[`g_cast()`](https://belian-earth.github.io/garry/reference/g_cast.md),
...). Inputs must share a grid
([`align()`](https://belian-earth.github.io/garry/reference/align.md)
first otherwise); rasters on different graphs merge automatically.

## Usage

``` r
lazy_map(..., fn, dtype = NULL, bands = NULL)
```

## Arguments

- ...:

  `LazyRaster` inputs (at least one), or a single `LazyDataset`.

- fn:

  Function of as many arrays as there are inputs.

- dtype:

  Optional output dtype override.

- bands:

  `LazyDataset` only: bands to map over (default: all value bands).

## Value

A `LazyRaster`, or a `LazyDataset` when given one.

## Details

The output dtype defaults to the promoted input dtype; pass `dtype` when
`fn` changes the value domain, e.g. `"f32"` for a mask that introduces
NaN over an integer band.

Over a `LazyDataset`, `fn` is applied to every value band (a single
dataset input only); `bands` restricts which bands, and non-selected
bands pass through unchanged.

## See also

[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
