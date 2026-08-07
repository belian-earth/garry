# Apply garry's default GDAL configuration for remote COG reads.

Sets the GDAL config options the composite / warp-on-read path and
cloud-optimised remote reads want: HTTP multiplexing over HTTP/2, the
odc-stac retry cadence and timeouts, a capped block cache (GDAL defaults
to 5% of RAM *per process*, which many daemons would multiply),
single-range COG-header ingest, a skipped directory scan and a
raster-extension vsicurl allowlist for fast remote opens, and the MEM
driver open gate the direct warp needs.
[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)
calls this on every read daemon automatically; call it yourself for
host-side discovery reads or when you drive
[`mirai::daemons()`](https://mirai.r-lib.org/reference/daemons.html)
directly. Each option is set via `set_config_option`, so a value you set
afterwards wins.

## Usage

``` r
garry_gdal_config()
```

## Value

Invisibly `NULL`.

## Details

These are session-global GDAL settings. In particular
`GDAL_DISABLE_READDIR_ON_OPEN = EMPTY_DIR` speeds remote opens but can
hide sidecars (overviews, world files) for *local* multi-file reads in
the same session; pass `gdal_config = FALSE` to
[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)
to skip it.
