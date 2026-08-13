# Quantize physical values to integer digital numbers, on device.

The sink-side write transform `round((x - offset) / scale)` – clamped to
`dtype`'s range (as GDAL's conversion would), with NaN mapped to
`nodata` BEFORE the integer cast (casting NaN to an integer is
undefined). Runs in f32 on the producer, so every execution route yields
byte-identical digital numbers; the writer daemon then only writes.

## Usage

``` r
g_quantize(x, scale, offset, nodata, dtype)
```

## Arguments

- x:

  Traced f32 array (physical values; NaN = nodata).

- scale, offset:

  Write quantization: `DN = round((x - offset) / scale)`.

- nodata:

  Integer sentinel NaN maps to (must fit `dtype`).

- dtype:

  Integer output dtype (`"u8"`, `"i8"`, `"i16"`, `"u16"`, `"i32"`).

## Value

Traced array of `dtype`.
