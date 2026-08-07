# Dequantize Alpha Earth (AEF) embedding codes.

The AEF Int8 decode `((x / 127.5)^2) * sign(x)`: per-value, nonlinear,
sign- preserving, mapping the code range `[-127, 127]` to ~`[-1, 1]`.
Written in the `g_*` vocabulary so it fuses onto the read as a garry map
(pass to
[`lazy_cog()`](https://belian-earth.github.io/garry/reference/lazy_cog.md)
`dequant =`) – on the device, not a separate decode pass.

## Usage

``` r
dequantize_aef(x)
```

## Arguments

- x:

  Int8 codes (traced array or plain numeric).

## Value

The dequantized values, same shape as `x`.
