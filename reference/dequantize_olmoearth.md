# Dequantize OlmoEarth embedding codes.

The OlmoEarth v1.3 embeddings (Ai2, published on Source Cooperative as a
Zarr v3 store) quantize each 128-dimension annual vector to Int8 with
the `signed_power` scheme, power 2: `sign(q) * (|q| / 127.5)^2`, with
`-128` as nodata. That is the decode
[`dequantize_aef()`](https://belian-earth.github.io/garry/reference/dequantize_aef.md)
applies too; this name records which product a pipeline reads.
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
turns the `-128` fill value into NaN at the read, so nodata stays NaN
through the decode.

## Usage

``` r
dequantize_olmoearth(x)
```

## Arguments

- x:

  Int8 codes (traced array or plain numeric).

## Value

The dequantized values, same shape as `x`.

## Details

Decode before any arithmetic: the quantization is nonlinear, so
distances between raw codes are not proportional to distances between
embeddings. The vectors are not unit length (the per-pixel norm over 128
dimensions is about 3.0 to 3.8); normalise them before taking a dot
product as cosine similarity.

## References

Team OlmoEarth et al. (2026). OlmoEarth v1.3 Embeddings. Ai2.
<https://allenai.org/papers/olmoearth-v1-3>

<https://source.coop/olmoearth/olmoearth-v1-3-embeddings>

## See also

[`dequantize_signed_power()`](https://belian-earth.github.io/garry/reference/dequantize_signed_power.md)
