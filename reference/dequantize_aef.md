# Dequantize Alpha Earth (AEF) embedding codes.

The AEF Int8 decode `((x / 127.5)^2) * sign(x)`: per-value, nonlinear,
sign- preserving, mapping the code range `[-127, 127]` to ~`[-1, 1]`.
Written in the `g_*` vocabulary, so applying it with
[`lazy_map()`](https://belian-earth.github.io/garry/reference/lazy_map.md)
after
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
fuses the decode onto the read, on the device rather than as a separate
decode pass. A read that resamples (`resampling = "average"`, or
[`coarsen()`](https://belian-earth.github.io/garry/reference/coarsen.md))
must decode first: pass the function as `lazy_dataset(decode = )`, which
decodes each code before any resampling. This is
[`dequantize_signed_power()`](https://belian-earth.github.io/garry/reference/dequantize_signed_power.md)
with its defaults.

## Usage

``` r
dequantize_aef(x)
```

## Arguments

- x:

  Int8 codes (traced array or plain numeric).

## Value

The dequantized values, same shape as `x`.

## See also

[`dequantize_signed_power()`](https://belian-earth.github.io/garry/reference/dequantize_signed_power.md)
