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
  if (nzchar(env)) {
    return(env)
  }
  fetched <- file.path(tools::R_user_dir("garry", "data"), "ocm-v4")
  if (length(list.files(fetched, pattern = "safetensors$"))) {
    return(fetched)
  }
  base <- path.expand("~/.local/share/omnicloudmask")
  if (!dir.exists(base)) {
    return(fetched)
  }
  vers <- sort(list.dirs(base, recursive = FALSE), decreasing = TRUE)
  if (length(vers)) vers[[1L]] else fetched
}

#' Cloud and shadow masking with OmniCloudMask
#'
#' Native (no-Python) implementation of the OmniCloudMask v4 cloud and
#' shadow segmentation model, which predicts per-pixel classes from
#' red, green, and NIR reflectance at 10-50 m resolution. Three
#' functions cover the workflow:
#'
#' * `ocm_model()` loads the pre-trained weights (see
#'   [ocm_fetch_weights()]) and builds the reusable inference kernel.
#'   One model object serves any number of scenes and datasets; all
#'   stages sharing a model compile to a single kernel per worker.
#' * `ocm_predict()` runs the model over three band `LazyRaster`s and
#'   returns the class band as a new `LazyRaster`. Like every garry
#'   verb it is lazy: nothing reads or computes until [collect()].
#' * `ocm_mask()` is the one-step verb for a `LazyDataset`: it derives
#'   the class band from three of the dataset's bands for every time
#'   slice, then masks every value band with it via [mask()]. The
#'   derived class band is consumed by the masking, exactly like a QA
#'   `mask_asset`.
#'
#' Predicted classes are 0 (clear), 1 (thick cloud), 2 (thin cloud),
#' and 3 (cloud shadow), with `NaN` wherever the input had nodata.
#'
#' @details
#' `halo` is the overlap margin each chunk recomputes so that chunk
#' seams carry full spatial context (OmniCloudMask itself blends
#' overlapping patches; garry crops instead). The per-window
#' normalisation makes results inherently window-dependent, exactly as
#' OmniCloudMask's are patch-dependent, so expect class agreement with
#' the Python implementation, not bit identity, except in the
#' single-chunk case.
#'
#' Weights are the OmniCloudMask authors'
#' (<https://github.com/DPIRD-DMA/OmniCloudMask>) and are not
#' distributed with garry; download them once with
#' [ocm_fetch_weights()].
#'
#' @param weights_dir Directory with the OCM v4 safetensors files.
#'   Defaults to the `GARRY_OCM_WEIGHTS` environment variable if set,
#'   then the [ocm_fetch_weights()] download directory, then the newest
#'   version under the Python package's cache
#'   (`~/.local/share/omnicloudmask`).
#' @param models Ensemble members to run; the default matches
#'   OmniCloudMask v4 exactly (both U-Nets, logits averaged). A single
#'   member is roughly twice as fast at slightly lower accuracy.
#' @param halo Chunk overlap margin in pixels (multiple of 32
#'   recommended).
#' @return `ocm_model()` returns an `ocm_model` object; `ocm_predict()`
#'   a class `LazyRaster` on the shared spatial grid; `ocm_mask()` the
#'   masked `LazyDataset` (class band consumed).
#' @seealso [ocm_fetch_weights()] to download the weights; [mask()] and
#'   [qa_bits()] for masking from an existing QA band;
#'   `vignette("omnicloudmask", package = "garry")` for a worked
#'   example.
#' @examples
#' \dontrun{
#' ocm_fetch_weights()  # once per machine
#' ds <- ds |> ocm_mask(red = "B04", green = "B03", nir = "B8A")
#' composite <- ds |> reduce_over("time", "median") |> collect()
#' }
#' @rdname ocm
#' @export
ocm_model <- function(
  weights_dir = NULL,
  models = c("regnety", "edgenext"),
  halo = 128L
) {
  models <- match.arg(models, c("regnety", "edgenext"), several.ok = TRUE)
  halo <- as.integer(halo)
  if (length(halo) != 1L || is.na(halo) || halo < 32L) {
    cli::cli_abort("{.arg halo} must be a single integer >= 32")
  }
  wl <- ocm_load_weights(weights_dir %||% .ocm_default_dir(), models = models)
  weights <- wl$weights
  fn <- function(x) .ocm_infer(x, weights)
  # Kernel pricing, calibrated 2026-08-06 against VmHWM deltas of the
  # warm two-model kernel at 640/1280/1920 px windows on the CPU PJRT
  # client: marginal ~610-700 B/px for the ensemble (decreasing with
  # window size), plus ~1.2 GB fixed per process (weights + compile
  # arenas) that amortises over the chunk and is corrected at run time
  # by the fleet RSS measurement. flops from the full-resolution
  # decoder tail, ~3-4e4/px per model.
  structure(
    list(
      fn = fn,
      kernel_id = paste0(
        "ocm-",
        wl$kernel_id,
        "-",
        paste(models, collapse = "+")
      ),
      halo = halo,
      bytes_px = 350 * length(models),
      flops_px = 4e4 * length(models),
      models = models
    ),
    class = "garry_ocm_model"
  )
}

.ocm_predict_stack <- function(red, green, nir, model) {
  for (b in list(red, green, nir)) {
    .assert_class(b, LazyRaster, "LazyRaster")
  }
  st <- lazy_stack(list(red = red, green = green, nir = nir), along = "band")
  lazy_patch(
    st,
    model$fn,
    radius = model$halo,
    out_bands = 0L,
    dtype = "f32",
    kernel_id = model$kernel_id,
    bytes_px = model$bytes_px,
    flops_px = model$flops_px
  )
}

#' @param red,green,nir For `ocm_predict()`: band `LazyRaster`s on the
#'   same grid and graph. For `ocm_mask()`: names of the dataset bands
#'   to predict from (e.g. `"B04"`, `"B03"`, `"B8A"`).
#' @param model An `ocm_model` object, from `ocm_model()`.
#' @rdname ocm
#' @export
ocm_predict <- function(red, green, nir, model = ocm_model()) {
  .ocm_predict_stack(red, green, nir, model)
}

#' @param x A `LazyDataset` whose slices carry the three bands.
#' @param where Classes to mask out (default thick cloud, thin cloud,
#'   and shadow).
#' @param open,dilate Morphological cleanup, as in [mask()].
#' @rdname ocm
#' @export
ocm_mask <- function(
  x,
  red,
  green,
  nir,
  model = ocm_model(),
  where = 1:3,
  open = 0L,
  dilate = 0L
) {
  .assert_class(x, LazyDataset, "LazyDataset")
  for (b in c(red, green, nir)) {
    if (!b %in% names(x@bands)) {
      cli::cli_abort("no band {.val {b}} in the dataset")
    }
  }
  nr <- length(x@bands[[red]])
  if (length(x@bands[[green]]) != nr || length(x@bands[[nir]]) != nr) {
    cli::cli_abort(
      "bands {.val {red}}/{.val {green}}/{.val {nir}} must have the same slice count"
    )
  }
  slices <- stats::setNames(
    lapply(seq_len(nr), function(i) {
      .ocm_predict_stack(
        x@bands[[red]][[i]],
        x@bands[[green]][[i]],
        x@bands[[nir]][[i]],
        model
      )
    }),
    names(x@bands[[red]])
  )
  x[["ocm"]] <- slices
  mask(x, from = "ocm", where = where, open = open, dilate = dilate)
}

#' @export
print.garry_ocm_model <- function(x, ...) {
  cat(
    .glue(
      "<ocm_model> {paste(x$models, collapse = '+')}  ",
      "halo={x$halo}  kernel={x$kernel_id}"
    ),
    "\n",
    sep = ""
  )
  invisible(x)
}
