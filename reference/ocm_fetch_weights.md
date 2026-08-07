# Download the OmniCloudMask v4 model weights.

Fetches garry's mirror of the official OmniCloudMask v4 weights (two
safetensors files, ~58 MB total, unmodified from upstream; MIT licensed
by DPIRD-DMA, see the release's NOTICE.md for attribution and citation)
into a per-user data directory, verifying each file's content hash.
Idempotent: files already present and intact are not re-downloaded.
[`ocm_model()`](https://belian-earth.github.io/garry/reference/ocm_model.md)
finds this directory automatically.

## Usage

``` r
ocm_fetch_weights(dir = NULL, quiet = FALSE)
```

## Arguments

- dir:

  Destination directory (default:
  `tools::R_user_dir("garry", "data")/ocm-v4`).

- quiet:

  Suppress progress output.

## Value

The weights directory, invisibly.
