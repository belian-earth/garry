#' @include collect.R
NULL

#' Execute a lazy raster and stream it to a GeoTIFF.
#'
#' The file-writing sibling of [collect()]: executes the plan (same
#' routes, same daemons) and writes the result to `path`. On the
#' distributed scheduler, chunks stream to the file as they land, so the
#' full raster never sits in memory; the single-process executor and the
#' direct composite routes hold the result, then write it. A plan that only
#' reads writes window by window on either route. Returns the path
#' invisibly; `collect()` always returns the in-session array.
#'
#' `dtype` with `scale`/`offset` quantizes at the sink boundary: values
#' are stored as `round((v - offset) / scale)` (round half to even) and
#' the affine is written as band scale/offset metadata, so GDAL readers
#' (QGIS, `lazy_source(scale = TRUE)`) recover physical values. An int16
#' reflectance file is half the raw bytes of float32 and compresses far
#' better. NaN demotes to `nodata`, which is stored in DN units and must
#' sit outside the quantized data range.
#'
#' Integer outputs saturate: a value beyond the dtype's range is written
#' as the nearest limit, without a warning. When `nodata` is one of those
#' limits, quantized values saturate one step inside it, so they never
#' read back as nodata; choose `scale` and `offset` so the data fits.
#'
#' `cog = TRUE` streams to a tiled GeoTIFF, then finalises with one
#' `gdal_translate` pass to the COG driver (which is copy-only by design:
#' overviews precede full-res data). The extra sequential pass is the trade
#' every COG producer makes.
#'
#' Every write builds in a hidden temporary directory, `.garry-write-XXXX`,
#' in the target's directory, and moves into place only when the whole run
#' has succeeded, every sink and group of it. So a plan may read the file it
#' replaces and gets the old values, and a failed run leaves every target as
#' it was: a previous file byte for byte, an absent one absent. Until the
#' move the filesystem must hold both the old file and the new one. Missing
#' directories on the way to a target are created at the move. The target's
#' directory must be writable, even for a file that is, and a symlink at the
#' target is replaced, not followed.
#'
#' A failure during the moves themselves is an error naming what is already
#' in place and what is still as it was: earlier targets are replaced, later
#' ones are not. A raw cube whose `.bin` moved and whose `.vrt` did not is
#' named as mixed, and needs writing again. A session killed during a run
#' leaves its temporary directory behind, holding partial files, and the
#' targets as they were; delete it by hand. A `/vsi` target has no directory
#' to rename in, so it builds in the session's [tempdir()] and is copied; a URL
#' is refused, as GDAL writes to a store through its `/vsi` path.
#'
#' @param x A `LazyRaster`, a `LazyDataset` (bands assembled along the
#'   band axis), a named list of lazy rasters (multi-export: one plan,
#'   one file per sink), or a `LazyDatasetGroups` (the result of
#'   [group_by_time()]; one file per group via a `{group}` placeholder
#'   in `path`).
#' @param path Destination path. For a named-list input: a directory
#'   (files named `<sink>.tif`) or a named character vector keyed by sink.
#' @param dtype Output dtype override, one of `"u8"`, `"i8"`, `"u16"`, `"i16"`,
#'   `"u32"`, `"i32"`, `"f32"` or `"f64"`; default keeps the plan's dtype
#'   (usually `"f32"`). Values past an integer
#'   dtype's range saturate at its ends, so writing arithmetic on `u8` data,
#'   which declares `i16`, back to Byte means asking for `dtype = "u8"`.
#' @param scale,offset Quantization affine (see Details). Requires an
#'   integer `dtype` other than `"u32"`; `offset` defaults to 0.
#' @param nodata Sentinel written to the file and used for NaN demotion,
#'   in stored (DN) units. It must fit the output dtype, `dtype` or else
#'   the plan's own. Required when an integer output can contain NaN.
#' @param cog Write a Cloud Optimized GeoTIFF (see Details).
#' @param creation_options GDAL creation options (`"KEY=VALUE"`). With
#'   `cog = FALSE` these replace the default tiled-DEFLATE options of the
#'   streamed write (compression stays multi-threaded unless they set
#'   `NUM_THREADS`); with `cog = TRUE` they go to the COG translate pass
#'   (the temporary streamed file keeps the defaults). A `BLOCKSIZE`,
#'   `BLOCKXSIZE` or `BLOCKYSIZE` must be a positive whole number.
#' @param overview_resampling COG overview resampling (`cog = TRUE`
#'   only). `"average"` (default) suits continuous data; use `"nearest"`
#'   for categorical outputs like masks.
#' @param band_names Band descriptions written to the file, one per output
#'   band. Defaults to the dataset's band names, or the labels of a
#'   `band` stack; given, it takes precedence over both.
#' @param distributed As in [collect()].
#' @return The written path(s), invisibly (expanded per sink/group for
#'   list, directory, and `{group}` forms).
#' @seealso [collect()] to return the result in the R session;
#'   [materialise()] to checkpoint to local cubes and stay lazy.
#' @examples
#' f <- system.file("extdata", "garry-example.tif", package = "garry")
#' red <- lazy_source(f, band = 1L)
#' nir <- lazy_source(f, band = 3L)
#' out <- tempfile(fileext = ".tif")
#' write_tif((nir - red) / (nir + red), out)
#' file.exists(out)
#' @export
write_tif <- function(
  x,
  path,
  dtype = NULL,
  scale = NULL,
  offset = NULL,
  nodata = NULL,
  cog = FALSE,
  creation_options = NULL,
  overview_resampling = c(
    "average",
    "nearest",
    "bilinear",
    "cubic",
    "mode",
    "rms"
  ),
  band_names = NULL,
  distributed = garry_daemons_set()
) {
  if (!rlang::is_bool(cog)) {
    cli::cli_abort("{.arg cog} must be {.code TRUE} or {.code FALSE}.")
  }
  if (!cog && !missing(overview_resampling)) {
    cli::cli_abort("{.arg overview_resampling} needs {.code cog = TRUE}: a plain write has no overviews.")
  }
  overview_resampling <- rlang::arg_match(overview_resampling)
  if (!is.character(path) || !length(path) || anyNA(path)) {
    cli::cli_abort("{.arg path} must be a character path.")
  }
  if (any(grepl("\\.vrt$", path, ignore.case = TRUE))) {
    cli::cli_abort(c(
      "{.fn write_tif} writes GeoTIFFs; {.path .vrt} raw cubes are {.fn materialise}'s format.",
      "i" = "Use {.fn materialise} to checkpoint lazily."
    ))
  }

  writable <- c("u8", "i8", "u16", "i16", "u32", "i32", "f32", "f64")
  if (!is.null(dtype) && !(is.character(dtype) && length(dtype) == 1L && dtype %in% writable)) {
    cli::cli_abort("{.arg dtype} must be one of {.val {writable}}, not {.val {dtype}}.")
  }
  .check_creation_options(creation_options)

  quantizing <- !is.null(scale) || !is.null(offset)
  if (quantizing) {
    if (is.null(scale)) {
      cli::cli_abort("{.arg offset} needs {.arg scale}.")
    }
    scale <- as.numeric(scale)
    offset <- if (is.null(offset)) 0 else as.numeric(offset)
    if (
      length(scale) != 1L ||
        length(offset) != 1L ||
        !is.finite(scale) ||
        !is.finite(offset) ||
        scale == 0
    ) {
      cli::cli_abort(
        "{.arg scale}/{.arg offset} must be finite, non-zero length-1 numerics."
      )
    }
    if (is.null(dtype) || is.null(.g_int_range[[dtype]])) {
      cli::cli_abort(c(
        "quantization ({.arg scale}/{.arg offset}) needs an integer {.arg dtype} other than u32.",
        "i" = "e.g. {.code dtype = \"i16\"} for scaled reflectance."
      ))
    }
  }
  wspec <- list(
    dtype = dtype,
    scale = if (quantizing) scale else numeric(0),
    offset = if (quantizing) offset else numeric(0),
    options = if (!cog) creation_options else NULL
  )
  if (is.null(dtype) && !quantizing && is.null(wspec$options)) {
    wspec <- NULL
  }

  res <- .collect_impl(
    x,
    path = path,
    nodata = nodata,
    distributed = distributed,
    band_names = band_names,
    wspec = wspec,
    finish = if (cog) {
      function(work, targets) {
        .cog_finalise(work, targets, overview_resampling, creation_options)
      }
    }
  )
  invisible(res)
}

# Rewrite each file a run streamed as a COG, still in the temporary directory:
# the move into place is the write's, as for any other.
.cog_finalise <- function(work, targets, overview_resampling, creation_options) {
  cl <- c(
    "-of",
    "COG",
    "-q",
    "-co",
    paste0("OVERVIEW_RESAMPLING=", toupper(overview_resampling))
  )
  if (is.null(creation_options)) {
    cl <- c(cl, "-co", "COMPRESS=DEFLATE", "-co", "NUM_THREADS=ALL_CPUS")
  }
  for (o in creation_options) {
    cl <- c(cl, "-co", o)
  }
  for (i in seq_along(work)) {
    # a short name: GDAL's own temporaries extend it, and a name may be at the
    # filesystem's limit
    part <- tempfile("cog", tmpdir = dirname(work[[i]]), fileext = ".tif")
    res <- .gdal_attempt(gdal_translate_file(work[[i]], part, cl))
    why <- c(res$failed, if (file.exists(part)) .gtiff_incomplete(part) else "GDAL wrote no file")
    if (!length(why)) {
      why <- gdal_place(part, work[[i]])
    }
    if (length(why)) {
      cli::cli_abort(
        c("COG finalise failed for {.path {targets[[i]]}}.", "x" = "{why[[1L]]}"),
        class = c("garry_write_error", "garry_error")
      )
    }
  }
}

# Creation options as GDAL parses them: KEY=VALUE, or KEY:VALUE. GDAL reads
# a block size with atoi(), so BLOCKSIZE=abc is 0, and the COG driver then
# allocates without bound (54 GB in 45 s). It warns, but does not stop.
.check_creation_options <- function(options, call = rlang::caller_env()) {
  if (is.null(options)) {
    return(invisible(NULL))
  }
  if (!is.character(options) || !all(grepl("^[A-Za-z0-9_]+[=:]", options))) {
    cli::cli_abort(c(
      "{.arg creation_options} must be {.code KEY=VALUE} strings.",
      "i" = "For example {.code c(\"COMPRESS=ZSTD\", \"BLOCKSIZE=512\")}."
    ), class = c("garry_write_error", "garry_error"), call = call)
  }
  block <- options[grepl("^BLOCK[XY]?SIZE[=:]", options, ignore.case = TRUE)]
  size <- sub("^[^=:]+[=:]", "", block)
  n <- suppressWarnings(as.integer(size))
  bad <- block[!grepl("^[0-9]+$", size) | is.na(n) | n < 1L]
  if (length(bad)) {
    cli::cli_abort(
      "{.arg creation_options}: a block size must be a positive whole number, not {.val {bad}}.",
      class = c("garry_write_error", "garry_error"),
      call = call
    )
  }
  invisible(options)
}
