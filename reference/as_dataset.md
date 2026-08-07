# Assemble a lazy dataset from existing rasters.

Each entry of `bands` is either a single `LazyRaster` (one time slice,
or an already-reduced composite) or a list of per-slice `LazyRaster`s.
Rasters on different graphs are imported into one shared graph.

## Usage

``` r
as_dataset(bands, mask_asset = NULL)
```

## Arguments

- bands:

  A named list of `LazyRaster`s or lists of `LazyRaster`s.

- mask_asset:

  Optional name of the QA/mask band within `bands`.

## Value

A `LazyDataset`.
