# Read multi-band COGs into a lazy dataset via the cptkirk engine.

**Use `lazy_cog` for multi-band Cloud-Optimised GeoTIFFs** – files with
many bands in one COG, such as geo-embedding stacks (Alpha Earth's
64-band tiles). It reads through
[cptkirk](https://belian-earth.github.io/cptkirk/), whose async-tiff
reader opens each tile ONCE and streams all its band planes concurrently
– far faster than GDAL's one-open-per-band for tens of bands.

## Usage

``` r
lazy_cog(
  sources,
  grid,
  assets = NULL,
  bands = NULL,
  resampling = "near",
  names = NULL,
  mask_asset = NULL,
  granularity = "day",
  sort_field = "datetime",
  nodata = NULL,
  lon = NULL
)
```

## Arguments

- sources:

  A STAC `doc_items` (from
  [`stac_query()`](https://belian-earth.github.io/garry/reference/stac_query.md),
  optionally filtered) or a
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)-style
  dataframe for the time-series form; or a COG path / character vector
  of tiles (remote `http(s)://` or `/vsicurl/`) for the single form.

- grid:

  Target
  [`GridSpec()`](https://belian-earth.github.io/garry/reference/GridSpec.md).

- assets:

  Asset names to read (dataframe form; a band each).

- bands:

  Source band indices (single-COG form; default: all).

- resampling:

  GDAL resampling (default `"near"`, right for quantised codes).

- names:

  Optional band names (single-COG form; default `b<index>`).

- mask_asset:

  Optional QA asset carried through for
  [`mask()`](https://belian-earth.github.io/garry/reference/mask.md)
  (dataframe form).

- granularity:

  Time-slice granularity, e.g. `"day"` (dataframe form).

- sort_field:

  Overlap-resolution field for per-slice mosaics (dataframe form).

- nodata:

  Optional nodata override: one value, or a named vector per asset
  (dataframe form).

- lon:

  Optional longitude for local-time slicing (dataframe form).

## Value

A `LazyDataset`.

## Details

**For single-band-per-asset time series (HLS, Sentinel-2, Landsat), use
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
instead.** cptkirk's only lever is intra-file band concurrency, which
single-band files do not have, so `lazy_cog` there is no faster than
GDAL (and its per-file opens make it slower on many small reads).

The API mirrors
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
so the two are interchangeable in use: both build the same `LazyDataset`
and support the same
[`mask()`](https://belian-earth.github.io/garry/reference/mask.md) /
[`reduce_over()`](https://belian-earth.github.io/garry/reference/reduce_over.md)
/
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
verbs; only the read engine differs.

Two input forms:

- a
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)-style
  dataframe (`location`/`datetime`/`asset`) plus `assets` – a band per
  named asset, a per-`granularity` time slice per date, exactly the
  [`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
  shape (mirrors its signature);

- a character path or vector of a single (multi-band) COG or a mosaic of
  tiles – one time slice, a band per selected source band.

The read is LAZY: construction fetches nothing. At
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
each source set (one asset-slice, or the single COG's bands) is fetched
together in one cptkirk pass, staged as a grid-aligned native-dtype
raster, and read from there. The source nodata sentinel is carried
through so those pixels read as NaN. `lazy_cog` only reads: value
transforms (a decode such as
[`dequantize_aef()`](https://belian-earth.github.io/garry/reference/dequantize_aef.md),
scaling, ...) go downstream as maps (`lazy_map(ds, fn = ...)`), which
garry fuses onto the read at
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md).
