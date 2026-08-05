# ---------------------------------------------------------------------------
# OmniCloudMask user API: native cloud/shadow masking (no Python).
#
# ocm_model()   -> loads + folds weights, prices the kernel, returns the
#                  model object (weights closure, kernel_id, halo, cost)
# ocm_predict() -> class LazyRaster from three band LazyRasters, or a
#                  named per-slice list from a LazyDataset
# ocm_mask()    -> one-step: derive the class band per slice and mask
#                  the dataset's value bands with it
#
# Classes: 0 clear, 1 thick cloud, 2 thin cloud, 3 cloud shadow; NaN
# where the input had nodata. Weights are the OmniCloudMask authors'
# (github.com/DPIRD-DMA/OmniCloudMask) and are not distributed with
# garry; see ocm_load_weights().
# ---------------------------------------------------------------------------

.ocm_default_dir <- function() {
  env <- Sys.getenv("GARRY_OCM_WEIGHTS")
  if (nzchar(env)) return(env)
  base <- path.expand("~/.local/share/omnicloudmask")
  if (!dir.exists(base)) return(base)
  vers <- sort(list.dirs(base, recursive = FALSE), decreasing = TRUE)
  if (length(vers)) vers[[1L]] else base
}

#' Load the native OmniCloudMask model.
#'
#' Builds the inference kernel for [ocm_predict()] / [ocm_mask()]: reads
#' and folds the OCM v4 weights (cached; see [ocm_load_weights()]),
#' closes the forward pass over them, and prices the kernel for the
#' planner. The result is reusable across any number of scenes and
#' datasets; all per-slice stages sharing one model collapse to a
#' single compiled kernel per daemon.
#'
#' `halo` is the overlap margin each chunk recomputes so that chunk
#' seams carry full spatial context (OmniCloudMask itself blends
#' overlapping patches; garry crops instead). The per-window
#' normalisation makes results inherently window-dependent, exactly as
#' OCM's are patch-dependent, so expect class agreement with the Python
#' implementation, not bit identity, except in the single-chunk case.
#'
#' @param weights_dir Directory with the OCM v4 safetensors files;
#'   default: `GARRY_OCM_WEIGHTS`, else the newest version under the
#'   Python package's cache (`~/.local/share/omnicloudmask`).
#' @param models Ensemble members to run; the default matches OCM v4
#'   exactly (both U-Nets, logits averaged). A single member is ~2x
#'   faster at slightly lower accuracy.
#' @param halo Chunk overlap margin in pixels (multiple of 32
#'   recommended).
#' @return An `ocm_model` list: `fn`, `kernel_id`, `halo`, `bytes_px`,
#'   `flops_px`, `models`.
#' @export
ocm_model <- function(weights_dir = NULL,
                      models = c("regnety", "edgenext"), halo = 128L) {
  models <- match.arg(models, c("regnety", "edgenext"), several.ok = TRUE)
  halo <- as.integer(halo)
  if (length(halo) != 1L || is.na(halo) || halo < 32L)
    cli::cli_abort("{.arg halo} must be a single integer >= 32")
  wl <- ocm_load_weights(weights_dir %||% .ocm_default_dir(),
                         models = models)
  weights <- wl$weights
  fn <- function(x) .ocm_infer(x, weights)
  # Kernel pricing (calibration pass pending): a U-Net's live
  # activations peak around the full-resolution decoder tail (~48
  # channels of f32) plus XLA slack, inflated by the padded-window
  # ratio at ~1000 px chunks; flops are dominated by the decoder's
  # full-resolution 3x3 convs (~3-4e4/px per model).
  structure(list(
    fn = fn,
    kernel_id = paste0("ocm-", wl$kernel_id, "-",
                       paste(models, collapse = "+")),
    halo = halo,
    bytes_px = 800 * length(models),
    flops_px = 4e4 * length(models),
    models = models
  ), class = "garry_ocm_model")
}

.ocm_predict_stack <- function(red, green, nir, model) {
  for (b in list(red, green, nir))
    .assert_class(b, LazyRaster, "LazyRaster")
  st <- lazy_stack(list(red = red, green = green, nir = nir),
                   along = "band")
  lazy_patch(st, model$fn, radius = model$halo, out_bands = 0L,
             dtype = "f32", kernel_id = model$kernel_id,
             bytes_px = model$bytes_px, flops_px = model$flops_px)
}

#' Predict OmniCloudMask classes, natively.
#'
#' Runs the OCM U-Net over red/green/NIR `LazyRaster`s (same grid, same
#' graph) and returns per-pixel classes (0 clear, 1 thick cloud, 2 thin
#' cloud, 3 shadow; NaN at nodata) as a lazy raster: nothing computes
#' until `collect()`. For datasets, [ocm_mask()] derives and applies the
#' mask per slice in one call.
#'
#' @param red,green,nir Band `LazyRaster`s.
#' @param model An [ocm_model()].
#' @return A class `LazyRaster` on the spatial grid.
#' @export
ocm_predict <- function(red, green, nir, model = ocm_model()) {
  .ocm_predict_stack(red, green, nir, model)
}

#' Cloud/shadow mask a dataset with native OmniCloudMask.
#'
#' The one-step verb: derive the OCM class band from three of the
#' dataset's bands per time slice, then [mask()] every value band with
#' it (`where` selects the masked classes; morphology as in `mask()`).
#' The derived band is consumed by the masking, exactly like a QA
#' `mask_asset`.
#'
#' @param x A `LazyDataset` whose slices carry the three bands.
#' @param red,green,nir Band names (e.g. `"B04"`, `"B03"`, `"B8A"`).
#' @param model An [ocm_model()].
#' @param where Classes to mask out (default thick + thin cloud +
#'   shadow).
#' @param open,dilate Morphological cleanup, as in [mask()].
#' @return The masked `LazyDataset` (OCM band consumed).
#' @export
ocm_mask <- function(x, red, green, nir, model = ocm_model(),
                     where = 1:3, open = 0L, dilate = 0L) {
  .assert_class(x, LazyDataset, "LazyDataset")
  for (b in c(red, green, nir))
    if (!b %in% names(x@bands))
      cli::cli_abort("no band {.val {b}} in the dataset")
  nr <- length(x@bands[[red]])
  if (length(x@bands[[green]]) != nr || length(x@bands[[nir]]) != nr)
    cli::cli_abort("bands {.val {red}}/{.val {green}}/{.val {nir}} must have the same slice count")
  slices <- stats::setNames(lapply(seq_len(nr), function(i)
    .ocm_predict_stack(x@bands[[red]][[i]], x@bands[[green]][[i]],
                       x@bands[[nir]][[i]], model)),
    names(x@bands[[red]]))
  x[["ocm"]] <- slices
  mask(x, from = "ocm", where = where, open = open, dilate = dilate)
}

#' @export
print.garry_ocm_model <- function(x, ...) {
  cat(sprintf("<ocm_model> %s  halo=%d  kernel=%s\n",
              paste(x$models, collapse = "+"), x$halo, x$kernel_id))
  invisible(x)
}
