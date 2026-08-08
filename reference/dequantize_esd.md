# Dequantize Embedded Seamless Data (ESD) FSQ codes.

Decodes ONE level from packed Finite Scalar Quantisation indices: each
uint16 code factorises into `length(levels)` per-level integers via the
positional basis `B = cumprod(c(1, levels[-length(levels)]))`, and each
rescales to roughly `[-1, 1]`:

## Usage

``` r
dequantize_esd(x, level, levels = c(8L, 8L, 8L, 5L, 5L, 5L))
```

## Arguments

- x:

  Packed FSQ codes (traced array or plain numeric).

- level:

  Which level to decode (index into `levels`).

- levels:

  Integer vector of per-level cardinalities. Default
  `c(8L, 8L, 8L, 5L, 5L, 5L)` (the ESD quantiser).

## Value

The decoded level, same shape as `x`, in `[-1, 1]`.

## Details

\$\$c_j = \lfloor x / B_j \rfloor \bmod L_j, \quad v_j = (c_j - \lfloor
L_j/2 \rfloor) / \lfloor L_j/2 \rfloor\$\$

Written in the `g_*` vocabulary so it fuses onto the read as a garry map
(one
[`lazy_map()`](https://belian-earth.github.io/garry/reference/lazy_map.md)
per band and level) – on the device, not a separate decode pass.
Truncation toward zero is the double-cast idiom
`g_cast(g_cast(z, "i32"), "f32")` (XLA convert semantics); all
arithmetic is exact in f32 because codes are integers below
`prod(levels)` (64000 for the ESD default, well under 2^24). NaN
(nodata, D8) is re-masked explicitly after the decode: casting NaN to an
integer is undefined, so propagation through the casts cannot be relied
on.

The default `levels` matches the ESD upstream quantiser (12 monthly
uint16 bands x 6 levels = 72 embedding channels). Any FSQ-packed product
decodes by passing its own `levels`.

## References

Chen S., et al. ESD quantiser:
<https://github.com/shuangchencc/ESD/blob/main/esd_quantizer.py>

Mentzer F., Minnen D., Agustsson E., Tschannen M. (2024). Finite scalar
quantization: VQ-VAE made simple. ICLR.
