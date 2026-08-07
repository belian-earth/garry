# Download an AnvlArray as a raw store payload.

Row-major byte payload tagged with `gdim`/`gdt` (D20, extended to f64 by
design/f64-store.md); no double materialisation. Raw f64 is
bit-identical to the doubles path.

## Usage

``` r
g_download_raw(x)
```

## Arguments

- x:

  `AnvlArray` (f32 or f64).

## Value

Raw vector with `gdim` and `gdt` attributes.
