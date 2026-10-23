# Dequantize signed-power embedding codes.

The decode `sign(x) * (|x| / scale)^power`: per-value, nonlinear and
sign-preserving. Geo-embedding products store float vectors as Int8
codes this way, spending more codes near zero where most values sit;
with the usual `scale = 127.5` the code range `[-127, 127]` maps to
about `[-1, 1]`. The `signed_power` method of the Embeddings Zarr
Convention's `geoemb:quantization` metadata names the two parameters.
[`dequantize_aef()`](https://belian-earth.github.io/garry/reference/dequantize_aef.md)
and
[`dequantize_olmoearth()`](https://belian-earth.github.io/garry/reference/dequantize_olmoearth.md)
are this decode with `power = 2`.

## Usage

``` r
dequantize_signed_power(x, power = 2, scale = 127.5)
```

## Arguments

- x:

  Int8 codes (traced array or plain numeric).

- power:

  Exponent of the decode (`2` for AEF and OlmoEarth).

- scale:

  Code magnitude that decodes to 1 (`127.5` for both).

## Value

The dequantized values, same shape as `x`.

## Details

Written in the `g_*` vocabulary, so applying it with
[`lazy_map()`](https://belian-earth.github.io/garry/reference/lazy_map.md)
after
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
fuses the decode onto the read, on the device rather than as a separate
decode pass. A nodata code (`-128` in both products) must reach the
decode as NaN:
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
does that whenever the source declares it (a GeoTIFF nodata value, a
Zarr fill value), and NaN passes through the decode unchanged.

## See also

[`dequantize_aef()`](https://belian-earth.github.io/garry/reference/dequantize_aef.md),
[`dequantize_olmoearth()`](https://belian-earth.github.io/garry/reference/dequantize_olmoearth.md)
