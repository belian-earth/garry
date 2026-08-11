# Cloud and shadow masking with OmniCloudMask

Native (no-Python) implementation of the OmniCloudMask v4 cloud and
shadow segmentation model, which predicts per-pixel classes from red,
green, and NIR reflectance at 10-50 m resolution. Three functions cover
the workflow:

## Usage

``` r
ocm_model(weights_dir = NULL, models = c("regnety", "edgenext"), halo = 128L)

ocm_predict(red, green, nir, model = ocm_model())

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

- weights_dir:

  Directory with the OCM v4 safetensors files. Defaults to the
  `GARRY_OCM_WEIGHTS` environment variable if set, then the
  [`ocm_fetch_weights()`](https://belian-earth.github.io/garry/reference/ocm_weights.md)
  download directory, then the newest version under the Python package's
  cache (`~/.local/share/omnicloudmask`).

- models:

  Ensemble members to run; the default matches OmniCloudMask v4 exactly
  (both U-Nets, logits averaged). A single member is roughly twice as
  fast at slightly lower accuracy.

- halo:

  Chunk overlap margin in pixels (multiple of 32 recommended).

- red, green, nir:

  For `ocm_predict()`: band `LazyRaster`s on the same grid and graph.
  For `ocm_mask()`: names of the dataset bands to predict from (e.g.
  `"B04"`, `"B03"`, `"B8A"`).

- model:

  An `ocm_model` object, from `ocm_model()`.

- x:

  A `LazyDataset` whose slices carry the three bands.

- where:

  Classes to mask out (default thick cloud, thin cloud, and shadow).

- open, dilate:

  Morphological cleanup, as in
  [`mask()`](https://belian-earth.github.io/garry/reference/mask.md).

## Value

`ocm_model()` returns an `ocm_model` object; `ocm_predict()` a class
`LazyRaster` on the shared spatial grid; `ocm_mask()` the masked
`LazyDataset` (class band consumed).

## Details

- `ocm_model()` loads the pre-trained weights (see
  [`ocm_fetch_weights()`](https://belian-earth.github.io/garry/reference/ocm_weights.md))
  and builds the reusable inference kernel. One model object serves any
  number of scenes and datasets; all stages sharing a model compile to a
  single kernel per worker.

- `ocm_predict()` runs the model over three band `LazyRaster`s and
  returns the class band as a new `LazyRaster`. Like every garry verb it
  is lazy: nothing reads or computes until
  [`collect()`](https://belian-earth.github.io/garry/reference/collect.md).

- `ocm_mask()` is the one-step verb for a `LazyDataset`: it derives the
  class band from three of the dataset's bands for every time slice,
  then masks every value band with it via
  [`mask()`](https://belian-earth.github.io/garry/reference/mask.md).
  The derived class band is consumed by the masking, exactly like a QA
  `mask_asset`.

Predicted classes are 0 (clear), 1 (thick cloud), 2 (thin cloud), and 3
(cloud shadow), with `NaN` wherever the input had nodata.

`halo` is the overlap margin each chunk recomputes so that chunk seams
carry full spatial context (OmniCloudMask itself blends overlapping
patches; garry crops instead). The per-window normalisation makes
results inherently window-dependent, exactly as OmniCloudMask's are
patch-dependent, so expect class agreement with the Python
implementation, not bit identity, except in the single-chunk case.

Weights are the OmniCloudMask authors'
(<https://github.com/DPIRD-DMA/OmniCloudMask>) and are not distributed
with garry; download them once with
[`ocm_fetch_weights()`](https://belian-earth.github.io/garry/reference/ocm_weights.md).

## See also

[`ocm_fetch_weights()`](https://belian-earth.github.io/garry/reference/ocm_weights.md)
to download the weights;
[`mask()`](https://belian-earth.github.io/garry/reference/mask.md) and
[`qa_bits()`](https://belian-earth.github.io/garry/reference/qa_bits.md)
for masking from an existing QA band;
[`vignette("omnicloudmask", package = "garry")`](https://belian-earth.github.io/garry/articles/omnicloudmask.md)
for a worked example.

## Examples

``` r
if (FALSE) { # \dontrun{
ocm_fetch_weights()  # once per machine
ds <- ds |> ocm_mask(red = "B04", green = "B03", nir = "B8A")
composite <- ds |> reduce_over("time", "median") |> collect()
} # }
```
