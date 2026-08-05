# ---------------------------------------------------------------------------
# OmniCloudMask weight ingestion: safetensors state dict -> the nested
# named weight list the forward-pass blocks consume, with batch norm
# folded into the preceding convolution (inference only):
#
#   W'[o, ...] = W[o, ...] * gamma[o] / sqrt(var[o] + eps)
#   b'[o]      = beta[o] + (b[o] - mean[o]) * gamma[o] / sqrt(var[o] + eps)
#
# LayerNorms (edgenext) are input-dependent and stay as gamma/beta
# vectors. Every extraction asserts its expected shape, so a wrong or
# truncated weight file fails loudly at build, not at kernel trace.
# ---------------------------------------------------------------------------

.ocm_eps <- 1e-5

# Fold one conv + BN pair from a flat state dict. `conv` names the conv
# weight key; `bn` the BN prefix (expects .weight/.bias/.running_mean/
# .running_var). A conv bias key may be absent (torch conv bias = 0).
.ocm_fold_conv_bn <- function(std, conv, bn) {
  w <- std[[conv]]
  if (is.null(w)) cli::cli_abort("missing tensor {.val {conv}}")
  g  <- std[[paste0(bn, ".weight")]]
  b  <- std[[paste0(bn, ".bias")]]
  mu <- std[[paste0(bn, ".running_mean")]]
  v  <- std[[paste0(bn, ".running_var")]]
  if (is.null(g) || is.null(b) || is.null(mu) || is.null(v))
    cli::cli_abort("missing BN tensors under {.val {bn}}")
  s <- g / sqrt(v + .ocm_eps)
  list(w = sweep(w, 1L, s, `*`), b = as.numeric(b - mu * s))
}

# Plain conv with its own bias (no BN), e.g. the segmentation head.
.ocm_conv_bias <- function(std, prefix) {
  w <- std[[paste0(prefix, ".weight")]]
  b <- std[[paste0(prefix, ".bias")]]
  if (is.null(w) || is.null(b))
    cli::cli_abort("missing tensors under {.val {prefix}}")
  list(w = w, b = as.numeric(b))
}

.ocm_assert_dim <- function(x, d, what) {
  if (!identical(as.integer(dim(x)), as.integer(d)))
    cli::cli_abort("{what}: expected shape {.val {d}}, got {.val {dim(x)}}")
  x
}

# regnety_004 encoder + SMP Unet decoder + segmentation head, folded.
# Structure discovered from the state dict itself (block/stage counts,
# group widths, SE hidden sizes), asserted against the published
# regnety_004 configuration where it is load-bearing.
.ocm_weights_regnety <- function(std) {
  keys <- names(std)

  stem <- .ocm_fold_conv_bn(std, "encoder.model.stem.conv.weight",
                            "encoder.model.stem.bn")
  .ocm_assert_dim(stem$w, c(32L, 3L, 3L, 3L), "regnety stem")

  stages <- lapply(1:4, function(s) {
    bs <- unique(regmatches(keys, regexpr(
      sprintf("^encoder\\.model\\.s%d\\.b\\d+", s), keys)))
    bs <- bs[order(as.integer(sub(".*\\.b", "", bs)))]
    lapply(bs, function(p) {
      blk <- list(
        conv1 = .ocm_fold_conv_bn(std, paste0(p, ".conv1.conv.weight"),
                                  paste0(p, ".conv1.bn")),
        conv2 = .ocm_fold_conv_bn(std, paste0(p, ".conv2.conv.weight"),
                                  paste0(p, ".conv2.bn")),
        conv3 = .ocm_fold_conv_bn(std, paste0(p, ".conv3.conv.weight"),
                                  paste0(p, ".conv3.bn")),
        se_fc1 = .ocm_conv_bias(std, paste0(p, ".se.fc1")),
        se_fc2 = .ocm_conv_bias(std, paste0(p, ".se.fc2")))
      blk$groups <- dim(blk$conv2$w)[[1L]] %/% dim(blk$conv2$w)[[2L]]
      ds <- paste0(p, ".downsample.conv.weight")
      if (ds %in% keys)
        blk$downsample <- .ocm_fold_conv_bn(std, ds,
                                            paste0(p, ".downsample.bn"))
      blk
    })
  })
  widths <- vapply(stages, function(st) dim(st[[1L]]$conv3$w)[[1L]], 0L)
  if (!identical(widths, c(48L, 104L, 208L, 440L)))
    cli::cli_abort("unexpected regnety_004 stage widths: {.val {widths}}")

  decoder <- lapply(0:4, function(i) list(
    conv1 = .ocm_fold_conv_bn(
      std, sprintf("decoder.blocks.%d.conv1.0.weight", i),
      sprintf("decoder.blocks.%d.conv1.1", i)),
    conv2 = .ocm_fold_conv_bn(
      std, sprintf("decoder.blocks.%d.conv2.0.weight", i),
      sprintf("decoder.blocks.%d.conv2.1", i))))
  dch <- vapply(decoder, function(b) dim(b$conv1$w)[[1L]], 0L)
  if (!identical(dch, c(256L, 128L, 64L, 32L, 16L)))
    cli::cli_abort("unexpected SMP decoder channels: {.val {dch}}")

  head <- .ocm_conv_bias(std, "segmentation_head.0")
  .ocm_assert_dim(head$w, c(4L, 16L, 3L, 3L), "segmentation head")

  list(arch = "regnety_004", stem = stem, stages = stages,
       decoder = decoder, head = head)
}

# edgenext_small encoder (P5): ConvNeXt/SDTA blocks with LayerNorms.
.ocm_weights_edgenext <- function(std) {
  cli::cli_abort(c(
    "the edgenext ensemble member is not implemented yet.",
    "i" = "use {.code models = \"regnety\"} for now"))
}

#' Load and fold OmniCloudMask weights.
#'
#' Reads the OCM v4 safetensors state dicts, folds batch norms into
#' their convolutions, and returns the nested weight lists the native
#' forward pass consumes, cached as an `.rds` under
#' `tools::R_user_dir("garry", "cache")` keyed by the content hash of
#' the weight files (the same hash is the model's jit-cache identity).
#'
#' Weights are not distributed with garry: point `dir` at a directory
#' holding the official OmniCloudMask model files (for example the
#' Python package's download cache,
#' `~/.local/share/omnicloudmask/<version>/`).
#'
#' @param dir Directory containing the OCM v4 `.safetensors` files.
#' @param models Which ensemble members to load
#'   (`"regnety"`, `"edgenext"`).
#' @return List with `weights` (per model), `kernel_id`, `paths`.
#' @export
ocm_load_weights <- function(dir, models = c("regnety", "edgenext")) {
  models <- match.arg(models, several.ok = TRUE)
  dir <- path.expand(dir)
  pat <- c(regnety = "regnety_004", edgenext = "edgenext_small")
  paths <- vapply(models, function(m) {
    hits <- list.files(dir, pattern = paste0("OCM.*", pat[[m]],
                                             ".*state\\.safetensors$"),
                       full.names = TRUE)
    if (length(hits) != 1L)
      cli::cli_abort(c(
        "expected exactly one OCM v4 {.val {pat[[m]]}} weight file in {.path {dir}}; found {length(hits)}.",
        "i" = "official weights land there via the Python package: pip install omnicloudmask; omnicloudmask.download_models()"))
    hits
  }, "")

  hash <- rlang::hash(list(version = 1L,
                           lapply(paths, function(p) rlang::hash_file(p))))
  cache <- file.path(tools::R_user_dir("garry", "cache"), "ocm",
                     paste0(hash, ".rds"))
  if (file.exists(cache)) {
    out <- readRDS(cache)
    if (identical(sort(names(out$weights)), sort(models))) return(out)
  }

  weights <- lapply(stats::setNames(nm = models), function(m) {
    std <- safetensors_read(paths[[m]])
    switch(m,
      regnety  = .ocm_weights_regnety(std),
      edgenext = .ocm_weights_edgenext(std))
  })
  out <- list(weights = weights, kernel_id = hash, paths = paths)
  dir.create(dirname(cache), recursive = TRUE, showWarnings = FALSE)
  saveRDS(out, cache)
  out
}
