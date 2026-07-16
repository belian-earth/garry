# ---------------------------------------------------------------------------
# MLP band reducer: predict a trained feedforward network across a raster.
#
# The nonlinear sibling of band_project(): a custom reducer for
# reduce_over(cube, fn, over = "band") that collapses the feature/band
# axis to one prediction per pixel by running an extracted MLP
# (weights as plain R matrices) inside the fused chunk kernel. The
# whole chain -- standardise, matmuls, activations -- traces into ONE
# XLA kernel with the upstream decode/masking, so the raster is read
# once and never round-trips through R (the R-side masking and block
# shuffling is what dominates torch-based per-block prediction).
#
# Per chunk: reshape (band, y, x) -> (band, npix), then per layer
# H <- act(W %*% H + b), then reshape the (1, npix) output back to
# (y, x). `%*%` dispatches to anvl's matmul when traced and base R
# otherwise, so the same body is the executor kernel and the test
# oracle. ReLU is computed as (h + |h|)/2: a select-based ReLU maps
# NaN to 0, and NaN propagation is the masking contract -- any NaN
# feature poisons exactly its own pixel's matmul column, reproducing
# complete-cases semantics with no explicit mask.
# ---------------------------------------------------------------------------

#' An MLP band reducer (predict a trained network across the raster).
#'
#' Returns an anvl reducer `fn(x, dims)` for
#' `reduce_over(cube, fn, over = "band")`: standardises the band vector
#' (optional), then applies dense layers `act(W_l x + b_l)` with ReLU
#' between layers and `output_activation` on the last, yielding one
#' value per pixel. Weights come in as plain R matrices -- e.g. torch
#' `nn_linear` layers, whose `$weight` is already `(n_out, n_in)` so
#' `as.matrix(layer$weight)` / `as.numeric(layer$bias)` drop straight
#' in. Dropout layers are inference-time identities: skip them.
#'
#' NaN in any feature band yields NaN for that pixel (complete-cases
#' semantics); gate QA upstream by mapping bad pixels' features to NaN.
#' Target back-transforms (expm1, sinh, ...) compose downstream as an
#' ordinary `lazy_map`.
#'
#' @param weights List of layer weight matrices, each `(n_out, n_in)`,
#'   applied in order; `n_in` of the first layer = number of bands.
#' @param biases List of bias vectors (`n_out` each), same length as
#'   `weights`.
#' @param center,scale Optional per-band standardisation applied first:
#'   `(x - center) / scale`. Length = number of bands.
#' @param output_activation `"identity"` or `"sigmoid"` on the final
#'   layer (hidden layers are ReLU).
#' @return A function `fn(x, dims)` suitable for [reduce_over()]
#'   `over = "band"`.
#' @seealso [band_project()] for the linear case, [reduce_over()]
#' @export
mlp_project <- function(weights, biases, center = NULL, scale = NULL,
                        output_activation = c("identity", "sigmoid")) {
  output_activation <- match.arg(output_activation)
  if (!is.list(weights) || !is.list(biases) ||
      length(weights) != length(biases) || length(weights) < 1L)
    cli::cli_abort("{.arg weights} and {.arg biases} must be equal-length non-empty lists")
  weights <- lapply(weights, function(w) {
    w <- as.matrix(w)
    storage.mode(w) <- "double"
    w
  })
  biases <- lapply(biases, as.numeric)
  n_in <- ncol(weights[[1L]])
  for (l in seq_along(weights)) {
    if (length(biases[[l]]) != nrow(weights[[l]]))
      cli::cli_abort("layer {l}: bias length must equal nrow(weights)")
    if (l > 1L && ncol(weights[[l]]) != nrow(weights[[l - 1L]]))
      cli::cli_abort("layer {l}: ncol(weights) must equal the previous layer's nrow")
  }
  if (nrow(weights[[length(weights)]]) != 1L)
    cli::cli_abort("the final layer must have one output (nrow(weights) == 1)")
  ctr <- if (!is.null(center)) as.numeric(center)
  scl <- if (!is.null(scale)) as.numeric(scale)
  if (!is.null(ctr) && length(ctr) != n_in)
    cli::cli_abort("{.arg center} must have one value per input band ({n_in})")
  if (!is.null(scl) && length(scl) != n_in)
    cli::cli_abort("{.arg scale} must have one value per input band ({n_in})")
  force(output_activation)

  function(x, dims) {
    if (!identical(as.integer(dims), 1L))
      cli::cli_abort("mlp_project() reduces the leading band axis (margin 1); got {dims}")
    sh <- if (.g_traced(x)) .g_shape(x) else dim(x)
    if (length(sh) != 3L || sh[[1L]] != n_in)
      cli::cli_abort("expected a ({n_in}, y, x) chunk; got dims {paste(sh, collapse = 'x')}")
    ny <- sh[[2L]]; nx <- sh[[3L]]
    h <- .g_flatten_yx(x)                               # (band, npix)
    if (!is.null(ctr)) {
      b <- g_broadcast_arrays(h, matrix(ctr, n_in, 1L))
      h <- b[[1L]] - b[[2L]]
    }
    if (!is.null(scl)) {
      b <- g_broadcast_arrays(h, matrix(scl, n_in, 1L))
      h <- b[[1L]] / b[[2L]]
    }
    n_layers <- length(weights)
    for (l in seq_len(n_layers)) {
      h <- weights[[l]] %*% h                            # (n_out, npix)
      b <- g_broadcast_arrays(h, matrix(biases[[l]], nrow(weights[[l]]), 1L))
      h <- b[[1L]] + b[[2L]]
      h <- if (l < n_layers) {
        (h + abs(h)) / 2                                 # NaN-preserving ReLU
      } else if (output_activation == "sigmoid") {
        1 / (1 + exp(-h))
      } else {
        h
      }
    }
    .g_unflatten_yx(h, ny, nx)                           # (y, x)
  }
}
