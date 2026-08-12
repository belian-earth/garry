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
      .glue("^encoder\\.model\\.s{s}\\.b\\d+"), keys)))
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
      std, .glue("decoder.blocks.{i}.conv1.0.weight"),
      .glue("decoder.blocks.{i}.conv1.1")),
    conv2 = .ocm_fold_conv_bn(
      std, .glue("decoder.blocks.{i}.conv2.0.weight"),
      .glue("decoder.blocks.{i}.conv2.1"))))
  dch <- vapply(decoder, function(b) dim(b$conv1$w)[[1L]], 0L)
  if (!identical(dch, c(256L, 128L, 64L, 32L, 16L)))
    cli::cli_abort("unexpected SMP decoder channels: {.val {dch}}")

  head <- .ocm_conv_bias(std, "segmentation_head.0")
  .ocm_assert_dim(head$w, c(4L, 16L, 3L, 3L), "segmentation head")

  list(arch = "regnety_004", stem = stem, stages = stages,
       decoder = decoder, head = head)
}

# Plain (weight, bias) pair, any layer kind.
.ocm_wb <- function(std, prefix) {
  w <- std[[paste0(prefix, ".weight")]]
  b <- std[[paste0(prefix, ".bias")]]
  if (is.null(w) || is.null(b))
    cli::cli_abort("missing tensors under {.val {prefix}}")
  list(w = w, b = as.numeric(b))
}

# edgenext_small encoder (timm) + SMP Unet decoder. LayerNorms stay as
# gamma/beta (input-dependent, not foldable); decoder BNs fold as for
# regnety. Structure: dims 48/96/160/304, depths 3/3/9/3, the LAST
# block of stages 2..4 is an SDTA (split-transpose attention) block,
# Fourier pos-embed on stage 2's SDTA only.
.ocm_weights_edgenext <- function(std) {
  keys <- names(std)
  ln <- function(prefix) list(g = as.numeric(std[[paste0(prefix, ".weight")]]),
                              b = as.numeric(std[[paste0(prefix, ".bias")]]))

  stem <- list(conv = .ocm_wb(std, "encoder.model.stem_0"),
               ln   = ln("encoder.model.stem_1"))
  .ocm_assert_dim(stem$conv$w, c(48L, 3L, 4L, 4L), "edgenext stem")

  stages <- lapply(0:3, function(s) {
    pre <- .glue("encoder.model.stages_{s}")
    ds <- if (paste0(pre, ".downsample.1.weight") %in% keys)
      list(ln = ln(paste0(pre, ".downsample.0")),
           conv = .ocm_wb(std, paste0(pre, ".downsample.1")))
    bl <- unique(regmatches(keys, regexpr(
      .glue("^encoder\\.model\\.stages_{s}\\.blocks\\.\\d+"), keys)))
    bl <- bl[order(as.integer(sub(".*blocks\\.", "", bl)))]
    blocks <- lapply(bl, function(p) {
      sdta <- paste0(p, ".xca.qkv.weight") %in% keys
      base <- list(
        sdta  = sdta,
        norm  = ln(paste0(p, ".norm")),
        fc1   = .ocm_wb(std, paste0(p, ".mlp.fc1")),
        fc2   = .ocm_wb(std, paste0(p, ".mlp.fc2")),
        gamma = as.numeric(std[[paste0(p, ".gamma")]]))
      if (!sdta) {
        base$conv_dw <- .ocm_wb(std, paste0(p, ".conv_dw"))
        return(base)
      }
      ci <- unique(regmatches(keys, regexpr(
        .glue("^{gsub('\\.', '\\\\.', p)}\\.convs\\.\\d+"), keys)))
      ci <- ci[order(as.integer(sub(".*convs\\.", "", ci)))]
      base$convs <- lapply(ci, function(cp) .ocm_wb(std, cp))
      base$norm_xca <- ln(paste0(p, ".norm_xca"))
      base$gamma_xca <- as.numeric(std[[paste0(p, ".gamma_xca")]])
      base$xca <- list(
        qkv  = .ocm_wb(std, paste0(p, ".xca.qkv")),
        proj = .ocm_wb(std, paste0(p, ".xca.proj")),
        temperature = as.numeric(std[[paste0(p, ".xca.temperature")]]))
      pe <- paste0(p, ".pos_embd.token_projection")
      if (paste0(pe, ".weight") %in% keys) base$pos <- .ocm_wb(std, pe)
      base
    })
    list(downsample = ds, blocks = blocks)
  })
  widths <- vapply(stages, function(st) {
    b1 <- st$blocks[[1L]]
    if (is.null(b1$conv_dw)) length(b1$gamma) else dim(b1$conv_dw$w)[[1L]]
  }, 0L)
  if (!identical(widths, c(48L, 96L, 160L, 304L)))
    cli::cli_abort("unexpected edgenext_small stage widths: {.val {widths}}")

  decoder <- lapply(0:4, function(i) list(
    conv1 = .ocm_fold_conv_bn(
      std, .glue("decoder.blocks.{i}.conv1.0.weight"),
      .glue("decoder.blocks.{i}.conv1.1")),
    conv2 = .ocm_fold_conv_bn(
      std, .glue("decoder.blocks.{i}.conv2.0.weight"),
      .glue("decoder.blocks.{i}.conv2.1"))))
  if (!identical(dim(decoder[[1L]]$conv1$w), c(256L, 464L, 3L, 3L)))
    cli::cli_abort("unexpected edgenext decoder block 0 shape")

  head <- .ocm_conv_bias(std, "segmentation_head.0")
  .ocm_assert_dim(head$w, c(4L, 16L, 3L, 3L), "segmentation head")

  list(arch = "edgenext_small", stem = stem, stages = stages,
       decoder = decoder, head = head)
}

# The mirrored OCM v4 release (unmodified upstream safetensors + a
# NOTICE.md with attribution, licence, citation, and these hashes).
.ocm_release_base <- paste0(
  "https://github.com/belian-earth/garry/releases/download/ocm-weights-v4/")
.ocm_release_files <- c(
  regnety  = "PM_model_OCM_7.97_R_G_NIR_3_smp_regnety_004.pycls_in1k_PT_state.safetensors",
  edgenext = "PM_model_OCM_7.97_R_G_NIR_3_smp_edgenext_small.usi_in1k_PT_state.safetensors")
.ocm_release_hash <- c(
  regnety  = "44bccacce24f4ddd4ba08eaa763c2d04",
  edgenext = "8556cbea5e7b14b2de2e2a9f6d784331")

#' OmniCloudMask model weights
#'
#' `ocm_fetch_weights()` downloads garry's mirror of the official
#' OmniCloudMask v4 weights (two safetensors files, about 58 MB total,
#' unmodified from upstream; MIT licensed by DPIRD-DMA, see the
#' release's `NOTICE.md` for attribution and citation) into a per-user
#' data directory, verifying each file's content hash. It is
#' idempotent: files already present and intact are not re-downloaded.
#' [ocm_model()] finds this directory automatically, so most users need
#' nothing beyond a one-off `ocm_fetch_weights()`.
#'
#' `ocm_load_weights()` is the lower-level loader `ocm_model()` uses:
#' it reads the safetensors state dicts, folds batch norms into their
#' convolutions, and returns the nested weight lists the native forward
#' pass consumes. Results are cached as an `.rds` under
#' `tools::R_user_dir("garry", "cache")`, keyed by the content hash of
#' the weight files. Call it directly only to point at a non-standard
#' weights directory, for example the Python package's download cache
#' (`~/.local/share/omnicloudmask/<version>/`).
#'
#' @param dir For `ocm_fetch_weights()`: destination directory
#'   (default: `tools::R_user_dir("garry", "data")/ocm-v4`). For
#'   `ocm_load_weights()`: directory containing the OCM v4
#'   `.safetensors` files.
#' @param quiet Suppress progress output.
#' @return `ocm_fetch_weights()` returns the weights directory,
#'   invisibly. `ocm_load_weights()` returns a list with `weights` (one
#'   entry per model), `kernel_id`, and `paths`.
#' @seealso [ocm_model()], [ocm_mask()] and [ocm_predict()] for running
#'   the model; [safetensors_read()] for the underlying file format.
#' @rdname ocm_weights
#' @export
ocm_fetch_weights <- function(dir = NULL, quiet = FALSE) {
  dir <- dir %||% file.path(tools::R_user_dir("garry", "data"), "ocm-v4")
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  for (m in names(.ocm_release_files)) {
    f <- .ocm_release_files[[m]]
    dest <- file.path(dir, f)
    if (file.exists(dest) &&
        identical(rlang::hash_file(dest), .ocm_release_hash[[m]])) {
      if (!quiet) cli::cli_inform("{.file {f}} already present, verified.")
      next
    }
    if (!quiet) cli::cli_inform("downloading {.file {f}} ...")
    tmp <- paste0(dest, ".part")
    status <- utils::download.file(paste0(.ocm_release_base, f), tmp,
                                   mode = "wb", quiet = quiet)
    if (status != 0L || !file.exists(tmp)) {
      unlink(tmp)
      cli::cli_abort("download failed for {.file {f}}")
    }
    if (!identical(rlang::hash_file(tmp), .ocm_release_hash[[m]])) {
      unlink(tmp)
      cli::cli_abort(c(
        "hash mismatch for downloaded {.file {f}}.",
        "i" = "the mirror may be corrupt or altered; not installing it"))
    }
    file.rename(tmp, dest)
  }
  invisible(dir)
}

#' @param models Which ensemble members to load
#'   (`"regnety"`, `"edgenext"`).
#' @rdname ocm_weights
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
        "i" = "download them with {.run garry::ocm_fetch_weights()}"))
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
