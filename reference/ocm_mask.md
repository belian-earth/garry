# Cloud/shadow mask a dataset with native OmniCloudMask.

The one-step verb: derive the OCM class band from three of the dataset's
bands per time slice, then
[`mask()`](https://belian-earth.github.io/garry/reference/mask.md) every
value band with it (`where` selects the masked classes; morphology as in
[`mask()`](https://belian-earth.github.io/garry/reference/mask.md)). The
derived band is consumed by the masking, exactly like a QA `mask_asset`.

## Usage

``` r
ocm_mask(
  x,
  red,
  green,
  nir,
  model = ocm_model(),
  where = 1:3,
  open = 0L,
  dilate = 0L
)
```

## Arguments

- x:

  A `LazyDataset` whose slices carry the three bands.

- red, green, nir:

  Band names (e.g. `"B04"`, `"B03"`, `"B8A"`).

- model:

  An
  [`ocm_model()`](https://belian-earth.github.io/garry/reference/ocm_model.md).

- where:

  Classes to mask out (default thick + thin cloud + shadow).

- open, dilate:

  Morphological cleanup, as in
  [`mask()`](https://belian-earth.github.io/garry/reference/mask.md).

## Value

The masked `LazyDataset` (OCM band consumed).
