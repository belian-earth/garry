# Elementwise map over one or more aligned rasters.

`fn` receives one traced array per input raster and returns one array;
it runs fused with adjacent operations in one compiled kernel. Write it
with plain arithmetic and the `g_*` vocabulary
([`g_ifelse()`](https://belian-earth.github.io/garry/reference/g_ifelse.md),
[`g_bitand()`](https://belian-earth.github.io/garry/reference/g-bitwise.md),
[`g_cast()`](https://belian-earth.github.io/garry/reference/g_cast.md),
...). Inputs must share a grid
([`align_to()`](https://belian-earth.github.io/garry/reference/align_to.md)
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

  Optional output dtype. Given, `fn` is not traced when the raster is
  built, so a kernel that only traces at chunk time can use it. Left
  out, it is what `fn` returns. Unsigned inputs compute in a wider dtype
  (`u8` in `i16`, `u16` in `i32`, `u32` in `i64`, `u64` in `f64`), so
  `fn` over them returns that unless told otherwise.

- bands:

  `LazyDataset` only: bands to map over (default: all value bands).

## Value

A `LazyRaster`, or a `LazyDataset` when given one.

## Details

The output dtype is the dtype `fn` returns, found by tracing it on
abstract inputs (nothing runs and nothing compiles). `dtype` overrides
it: the kernel's output is cast to `dtype`, which truncates a float to
an integer dtype and saturates at the ends of an unsigned one, and
everything downstream reads the cast value. A kernel returning a logical
stores 0/1 at the promoted input dtype, and
[`g_ifelse()`](https://belian-earth.github.io/garry/reference/g_ifelse.md)
reads such a mask with nonzero as true.

Over a `LazyDataset`, `fn` is applied to every value band (a single
dataset input only); `bands` restricts which bands, and non-selected
bands pass through unchanged.

## See also

[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)

## Examples

``` r
f <- system.file("extdata", "garry-example.tif", package = "garry")
red <- lazy_source(f, band = 1L)
nir <- lazy_source(f, band = 3L)
ndvi <- lazy_map(nir, red, fn = function(n, r) (n - r) / (n + r))
range(collect(ndvi))
#> Error in confirm_plugin_install(platform, url): The "cpu" PJRT plugin needs to be downloaded for pjrt to work.
#> ℹ Automatic downloads are not performed in non-interactive sessions.
#> ℹ Set `PJRT_INSTALL` to "1" to allow the download, or set
#>   `PJRT_PLUGIN_PATH_CPU` to a local plugin file.
```
