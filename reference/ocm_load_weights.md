# Load and fold OmniCloudMask weights.

Reads the OCM v4 safetensors state dicts, folds batch norms into their
convolutions, and returns the nested weight lists the native forward
pass consumes, cached as an `.rds` under
`tools::R_user_dir("garry", "cache")` keyed by the content hash of the
weight files (the same hash is the model's jit-cache identity).

## Usage

``` r
ocm_load_weights(dir, models = c("regnety", "edgenext"))
```

## Arguments

- dir:

  Directory containing the OCM v4 `.safetensors` files.

- models:

  Which ensemble members to load (`"regnety"`, `"edgenext"`).

## Value

List with `weights` (per model), `kernel_id`, `paths`.

## Details

Weights are not distributed with garry: point `dir` at a directory
holding the official OmniCloudMask model files (for example the Python
package's download cache, `~/.local/share/omnicloudmask/<version>/`).
