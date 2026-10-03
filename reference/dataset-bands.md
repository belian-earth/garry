# Bands of a lazy dataset

[`names()`](https://rdrr.io/r/base/names.html) lists a dataset's bands,
including any QA/mask band, and
[`length()`](https://rdrr.io/r/base/length.html) counts them. `ds$B04`
is `ds[["B04"]]`, and `ds$ndvi <- value` is `ds[["ndvi"]] <- value`.

## Arguments

- x:

  A `LazyDataset`.

- name:

  A band name.

- value:

  A `LazyRaster` (or a list of per-slice `LazyRaster`s) on the dataset's
  grid.

## Value

[`names()`](https://rdrr.io/r/base/names.html): a character vector.
[`length()`](https://rdrr.io/r/base/length.html): an integer. `$`: a
`LazyRaster`. `$<-`: the updated `LazyDataset`.
