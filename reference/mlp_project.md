# An MLP band reducer (predict a trained network across the raster).

Returns a reducer function `fn(x, dims)` for
`reduce_over(cube, fn, over = "band")`: standardises the band vector
(optional), then applies dense layers `act(W_l x + b_l)` with ReLU
between layers and `output_activation` on the last, yielding one value
per pixel. Weights come in as plain R matrices – e.g. torch `nn_linear`
layers, whose `$weight` is already `(n_out, n_in)` so
`as.matrix(layer$weight)` / `as.numeric(layer$bias)` drop straight in.
Dropout layers are inference-time identities: skip them.

## Usage

``` r
mlp_project(
  weights,
  biases,
  center = NULL,
  scale = NULL,
  output_activation = c("identity", "sigmoid"),
  qa_plane = NULL,
  qa_floor = NULL
)
```

## Arguments

- weights:

  List of layer weight matrices, each `(n_out, n_in)`, applied in order;
  `n_in` of the first layer = number of bands.

- biases:

  List of bias vectors (`n_out` each), same length as `weights`.

- center, scale:

  Optional per-band standardisation applied first:
  `(x - center) / scale`. Length = number of bands.

- output_activation:

  `"identity"` or `"sigmoid"` on the final layer (hidden layers are
  ReLU).

- qa_plane:

  Optional 1-based index of a QA plane riding as the LAST plane of the
  input cube (must equal `n_in + 1`). Predictions where the QA value is
  nodata (or below `qa_floor`) are NaN. Carrying QA inside the cube lets
  the whole prediction run as a single read with no separate masking
  pass.

- qa_floor:

  Optional minimum QA value; below it the prediction is NaN. Only used
  with `qa_plane`.

## Value

A function `fn(x, dims)` suitable for
[`reduce_over()`](https://belian-earth.github.io/garry/reference/reduce_over.md)
`over = "band"`.

## Details

NaN in any feature band yields NaN for that pixel (complete-cases
semantics); gate QA upstream by mapping bad pixels' features to NaN.
Target back-transforms (expm1, sinh, ...) compose downstream as an
ordinary `lazy_map`.

## See also

[`band_project()`](https://belian-earth.github.io/garry/reference/band_project.md)
for the linear case,
[`reduce_over()`](https://belian-earth.github.io/garry/reference/reduce_over.md)
