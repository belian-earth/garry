# Load the native OmniCloudMask model.

Builds the inference kernel for
[`ocm_predict()`](https://belian-earth.github.io/garry/reference/ocm_predict.md)
/
[`ocm_mask()`](https://belian-earth.github.io/garry/reference/ocm_mask.md):
reads and folds the OCM v4 weights (cached; see
[`ocm_load_weights()`](https://belian-earth.github.io/garry/reference/ocm_load_weights.md)),
closes the forward pass over them, and prices the kernel for the
planner. The result is reusable across any number of scenes and
datasets; all per-slice stages sharing one model collapse to a single
compiled kernel per daemon.

## Usage

``` r
ocm_model(weights_dir = NULL, models = c("regnety", "edgenext"), halo = 128L)
```

## Arguments

- weights_dir:

  Directory with the OCM v4 safetensors files; default:
  `GARRY_OCM_WEIGHTS`, else the newest version under the Python
  package's cache (`~/.local/share/omnicloudmask`).

- models:

  Ensemble members to run; the default matches OCM v4 exactly (both
  U-Nets, logits averaged). A single member is ~2x faster at slightly
  lower accuracy.

- halo:

  Chunk overlap margin in pixels (multiple of 32 recommended).

## Value

An `ocm_model` list: `fn`, `kernel_id`, `halo`, `bytes_px`, `flops_px`,
`models`.

## Details

`halo` is the overlap margin each chunk recomputes so that chunk seams
carry full spatial context (OmniCloudMask itself blends overlapping
patches; garry crops instead). The per-window normalisation makes
results inherently window-dependent, exactly as OCM's are
patch-dependent, so expect class agreement with the Python
implementation, not bit identity, except in the single-chunk case.
