#' @include passes.R executor.R ops.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Differentiable pipelines (Phase 6, decision D15).
#
# v1 scope: scalar losses of the shape
#   sources -> maps -> focal_kernel -> maps -> reduce(sum|mean over x,y)
# differentiated with respect to the focal kernel weights. Chunked
# gradients compose by linearity: for sum, dL/dw = sum_j ds_j/dw; for
# mean, L = sum(s_j)/sum(c_j) with the valid count c independent of w.
#
# Nodata handling is the MASK-MULTIPLY rewrite locked by gate 6.0:
# gradients through nan_rm reductions are NaN-poisoned whenever nodata
# multiplies the parameter (0 x NaN in the cotangent), so the grad-mode
# chunk loss zero-substitutes nodata in the inputs, carries a validity
# mask through the pipeline (window fully valid for focals), and
# reduces sum(out * mask) / sum(mask). Forward values agree with the
# nan_rm forward semantics: an output cell is NaN exactly when its
# window is not fully valid.
#
# Hard boundaries (documented, structurally rejected):
# - Warp on the tape: GDAL resampling is outside the tape (D15).
# - focal() with an arbitrary fn: not differentiable; use focal_kernel().
# - Non-algebraic or min/max losses: sum and mean only in v1.
# ---------------------------------------------------------------------------

# Grad-mode chunk loss: function(w, inputs) -> list(s, c).
# `w` is the flattened kernel (length (2r+1)^2, row-major over (dy, dx));
# `inputs` are RAW chunk arrays (NaN nodata), padded to the stage halo.
.grad_chunk_fn <- function(graph, stage, focal_id) {
  members <- stage@members
  input_nodes <- stage@input_nodes
  force(graph); force(focal_id)

  halo <- stage@halo
  function(w, inputs) {
    vals <- new.env(parent = emptyenv())
    masks <- new.env(parent = emptyenv())
    pads <- new.env(parent = emptyenv())
    for (i in seq_along(input_nodes)) {
      x <- inputs[[i]]
      k <- .key(input_nodes[[i]])
      assign(k, g_ifelse(g_is_nodata(x), 0, x), envir = vals)
      assign(k, g_cast(!g_is_nodata(x), "f32"), envir = masks)
      assign(k, halo, envir = pads)
    }

    for (id in members) {
      node <- graph_get(graph, id)
      pv <- lapply(node@parents, function(p) get(.key(p), envir = vals))
      pm <- lapply(node@parents, function(p) get(.key(p), envir = masks))
      pp <- vapply(node@parents, function(p) get(.key(p), envir = pads),
                   integer(1))

      if (S7::S7_inherits(node, MapNode)) {
        out_pad <- min(pp)
        pv <- Map(function(x2, d) .trim_to_pad(x2, d - out_pad),
                  pv, as.list(pp))
        pm <- Map(function(x2, d) .trim_to_pad(x2, d - out_pad),
                  pm, as.list(pp))
        v <- do.call(node@fn, pv)
        m <- Reduce(`*`, pm)
      } else if (S7::S7_inherits(node, FocalNode)) {
        r <- node@radius
        x <- pv[[1L]]; xm <- pm[[1L]]
        nr <- nrow(x) - 2L * r
        nc <- ncol(x) - 2L * r
        offsets <- expand.grid(dx = -r:r, dy = -r:r)
        v <- NULL; m <- NULL
        for (i in seq_len(nrow(offsets))) {
          sx <- g_shift_slice(x, offsets$dy[i], offsets$dx[i], nr, nc, r)
          sm <- g_shift_slice(xm, offsets$dy[i], offsets$dx[i], nr, nc, r)
          wi <- if (id == focal_id) g_index_scalar(w, i)
                else node@weights[[i]]
          term <- sx * wi
          v <- if (is.null(v)) term else v + term
          m <- if (is.null(m)) sm else m * sm
        }
        out_pad <- pp[[1L]] - r
      } else {
        .garry_error("unexpected node on the gradient tape",
                     "garry_grad_unsupported_error")
      }
      assign(.key(id), v, envir = vals)
      assign(.key(id), m, envir = masks)
      assign(.key(id), as.integer(out_pad), envir = pads)
    }

    tail_id <- members[[length(members)]]
    out <- get(.key(tail_id), envir = vals)
    mask <- get(.key(tail_id), envir = masks)
    list(s = g_sum(out * mask), c = g_sum(mask))
  }
}

# Validate the plan shape for v1 differentiation; returns the pieces.
.grad_validate <- function(plan, wrt) {
  kinds <- vapply(plan@stages, function(s) s@kind, character(1))
  if (any(kinds == "warp"))
    .garry_error(paste0(
      "the loss pipeline contains a warp: GDAL resampling is outside ",
      "the gradient tape (D15). align() inputs, materialise, then fit."),
      "garry_grad_unsupported_error")
  if (sum(kinds == "compute") != 1L ||
      sum(kinds == "reduce_combine") != 1L)
    .garry_error(paste0(
      "v1 differentiates pipelines of shape sources -> maps -> ",
      "focal_kernel -> maps -> reduce(sum|mean over x, y) only"),
      "garry_grad_unsupported_error")

  compute <- plan@stages[[which(kinds == "compute")]]
  rnode <- plan@graph |> graph_get(
    plan@stages[[which(kinds == "reduce_combine")]]@members[[1L]])
  if (!rnode@op %in% c("sum", "mean"))
    .garry_error(paste0(
      "loss reduction must be sum or mean; got ", rnode@op),
      "garry_grad_unsupported_error")

  for (id in compute@members) {
    node <- graph_get(plan@graph, id)
    if (S7::S7_inherits(node, FocalNode) && length(node@weights) == 0L)
      .garry_error(paste0(
        "focal() with an arbitrary fn is not differentiable; ",
        "use focal_kernel()"), "garry_grad_unsupported_error")
    if (S7::S7_inherits(node, ReduceNode))
      .garry_error("chunk-local reductions on the gradient tape are not supported in v1",
                   "garry_grad_unsupported_error")
    if (S7::S7_inherits(node, ScanNode))
      .garry_error("scans on the gradient tape are not supported (anvl's while loop has no reverse rule)",
                   "garry_grad_unsupported_error")
  }

  if (!wrt@node_id %in% compute@members)
    .garry_error("`wrt` is not part of the loss pipeline's compute stage",
                 "garry_grad_unsupported_error")
  wnode <- graph_get(plan@graph, wrt@node_id)
  if (!S7::S7_inherits(wnode, FocalNode) || length(wnode@weights) == 0L)
    .garry_error("`wrt` must be a focal_kernel() LazyRaster",
                 "garry_grad_unsupported_error")

  list(compute = compute, rnode = rnode, focal = wnode)
}

#' Value and gradient of a scalar LazyRaster loss wrt a focal kernel.
#'
#' `loss` must be a scalar pipeline (global `sum` or `mean` reduction)
#' containing `wrt`, a `focal_kernel()` raster whose weights are the
#' parameters. Executes chunk by chunk (gradients compose by linearity)
#' with the mask-multiply nodata rewrite (D15).
#'
#' @param loss Scalar `LazyRaster` (reduced over x and y).
#' @param wrt The `focal_kernel()` LazyRaster to differentiate against.
#' @param weights Optional kernel matrix overriding the weights stored
#'   in `wrt` (used by optimisation loops to avoid rebuilding graphs).
#' @return `list(value = <scalar>, grad = <kernel-shaped matrix>)`.
#' @export
lazy_value_and_grad <- function(loss, wrt, weights = NULL) {
  stopifnot(S7::S7_inherits(loss, LazyRaster),
            S7::S7_inherits(wrt, LazyRaster))
  plan <- plan_lazy(loss)
  parts <- .grad_validate(plan, wrt)
  graph <- plan@graph
  compute <- parts$compute

  k <- 2L * parts$focal@radius + 1L
  w <- if (is.null(weights)) parts$focal@weights else as.numeric(t(weights))
  stopifnot(length(w) == k * k)

  vg <- g_value_and_gradient(
    function(w, inputs) {
      r <- .grad_chunk_fn(graph, compute, wrt@node_id)(w, inputs)
      r$s
    }, wrt = "w")
  cfn <- g_jit(function(w, inputs) {
    .grad_chunk_fn(graph, compute, wrt@node_id)(w, inputs)$c
  })

  # Source chunk reads mirror the executor's source_read stages.
  src_meta <- lapply(compute@input_nodes, function(nid) {
    node <- graph_get(graph, nid)
    if (!S7::S7_inherits(node, SourceNode))
      .garry_error("compute stage inputs must be sources on the gradient tape",
                   "garry_grad_unsupported_error")
    src_stage <- Find(function(s) nid %in% s@members, plan@stages)
    list(node = node, chunks = src_stage@chunks,
         dtype = node@grid@dtype)
  })

  it <- chunk_iter(src_meta[[1L]]$chunks)
  S <- 0; C <- 0; G <- 0
  w_up <- g_upload(w, "f32")
  for (j in seq_len(nrow(it))) {
    inputs <- lapply(src_meta, function(meta) {
      g_upload(.exec_read_padded(meta$node@path, meta$node@band,
                                 meta$node@nodata, meta$chunks, it[j, ],
                                 open_options = meta$node@open_options),
               meta$dtype)
    })
    r <- vg(w_up, inputs)
    S <- S + g_download(r$value)
    G <- G + g_download(r$grad$w)
    C <- C + g_download(cfn(w_up, inputs))
  }

  if (parts$rnode@op == "mean") {
    list(value = S / C, grad = matrix(G / C, k, k, byrow = TRUE))
  } else {
    list(value = S, grad = matrix(G, k, k, byrow = TRUE))
  }
}
