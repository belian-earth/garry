#' @include collect.R
NULL

#' Execute a lazy raster and stream it to a GeoTIFF.
#'
#' The file-writing sibling of [collect()]: executes the plan (same
#' routes, same daemons) and streams the result to `path` chunk by chunk,
#' so the full raster never sits in memory. Returns the path invisibly;
#' `collect()` always returns the in-session array.
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
#' `cog = TRUE` streams to a temporary tiled GeoTIFF beside `path`, then
#' finalises with one `gdal_translate` pass to the COG driver (which is
#' copy-only by design: overviews precede full-res data). The extra
#' sequential pass is the trade every COG producer makes; the temporary
#' file is removed even on failure, so `path` never holds a half-written
#' COG.
#'
#' @param x A `LazyRaster`, a `LazyDataset` (bands assembled along the
#'   band axis), a named list of lazy rasters (multi-export: one plan,
#'   one file per sink), or a `LazyDatasetGroups` (the result of
#'   [group_by_time()]; one file per group via a `{group}` placeholder
#'   in `path`).
#' @param path Destination path. For a named-list input: a directory
#'   (files named `<sink>.tif`) or a named character vector keyed by sink.
#' @param dtype Output dtype override (e.g. `"i16"`, `"u8"`); default
#'   keeps the plan's dtype (usually `"f32"`). Values past an integer
#'   dtype's range saturate at its ends, so writing arithmetic on `u8` data,
#'   which declares `i16`, back to Byte means asking for `dtype = "u8"`.
#' @param scale,offset Quantization affine (see Details). Requires an
#'   integer `dtype`; `offset` defaults to 0.
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

  # cog: stream to sibling temp target(s), then translate into place.
  work <- path
  tmp_dirs <- character(0)
  if (cog) {
    if (length(path) > 1L) {
      work <- stats::setNames(
        vapply(
          path,
          function(p) {
            tempfile("garry-cog-", tmpdir = dirname(p), fileext = ".tif")
          },
          character(1)
        ),
        names(path)
      )
    } else {
      # Stream into a temp dir under the target's fixed prefix, mirroring
      # the rest of the path (placeholders included), so each streamed
      # file's final path is its path relative to the temp dir, under the
      # prefix. The temp dir is removed on exit, whatever was streamed.
      # normalizePath: a relative target makes the prefix ".", and a
      # "./"-prefixed temp key would be invisible to any default ls()
      # over a path-keyed cache (the writer-close bug, 2026-08-13).
      ca <- .cog_anchor(path)
      cog_anchor <- ca$anchor
      dir.create(cog_anchor, recursive = TRUE, showWarnings = FALSE)
      td <- tempfile("garry-cog-", tmpdir = normalizePath(cog_anchor))
      dir.create(td)
      tmp_dirs <- td
      work <- if (nzchar(ca$rel)) file.path(td, ca$rel) else td
    }
    on.exit(
      unlink(c(unname(unlist(work)), tmp_dirs), recursive = TRUE),
      add = TRUE
    )
  }

  # a failed streamed write must not leave a half-written file behind
  # (the COG route already writes to temporaries), and a write refused
  # before it starts must not take the file it would have replaced
  done <- FALSE
  if (!cog) {
    targets <- .write_targets(x, path)
    was <- file.mtime(targets)
    on.exit(
      if (!done) unlink(targets[which(is.na(was) | file.mtime(targets) != was)]),
      add = TRUE
    )
  }
  res <- .collect_impl(
    x,
    path = work,
    nodata = nodata,
    distributed = distributed,
    band_names = band_names,
    wspec = wspec
  )
  done <- TRUE
  if (!cog) {
    return(invisible(res))
  }

  # Enumerate the streamed files (a directory target returns the dir).
  wf <- unname(unlist(res))
  streamed <- unique(unlist(lapply(wf, function(p) {
    if (dir.exists(p)) {
      list.files(p, "\\.tif$", full.names = TRUE, recursive = TRUE)
    } else {
      p
    }
  })))
  finals <- if (length(path) > 1L) {
    unname(unlist(path))[match(streamed, unname(unlist(work)))]
  } else {
    td <- normalizePath(tmp_dirs[[1L]])
    rel <- substring(normalizePath(streamed), nchar(td) + 2L)
    file.path(cog_anchor, rel)
  }
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
  for (i in seq_along(streamed)) {
    dir.create(dirname(finals[[i]]), recursive = TRUE, showWarnings = FALSE)
    # translate beside the target, then rename: an interrupted or failed
    # translate never leaves a partial COG at the final path
    part <- tempfile("garry-cog-", tmpdir = dirname(finals[[i]]), fileext = ".tif")
    res <- tryCatch(
      .gdal_attempt(gdal_translate_file(streamed[[i]], part, cl)),
      interrupt = function(e) {
        unlink(part)
        stop(e)
      }
    )
    why <- c(res$failed, if (file.exists(part)) .gtiff_incomplete(part) else "GDAL wrote no file")
    if (length(why) || !file.rename(part, finals[[i]])) {
      unlink(part)
      cli::cli_abort(
        c("COG finalise failed for {.path {finals[[i]]}}.", "x" = if (length(why)) "{why[[1L]]}"),
        class = c("garry_write_error", "garry_error")
      )
    }
  }
  invisible(if (length(finals) == 1L) finals[[1L]] else finals)
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

# Split a COG write target into its fixed prefix (an existing directory,
# or the path up to the first placeholder component) and the rest. A
# directory target has an empty rest.
.cog_anchor <- function(path) {
  if (dir.exists(path)) {
    return(list(anchor = path, rel = ""))
  }
  parts <- strsplit(path, "/", fixed = TRUE)[[1L]]
  k <- which(grepl("\\{(group|time)\\}", parts))[1L]
  if (is.na(k)) {
    k <- length(parts)
  }
  anchor <- paste(parts[seq_len(k - 1L)], collapse = "/")
  if (!nzchar(anchor)) {
    anchor <- if (startsWith(path, "/")) "/" else "."
  }
  list(anchor = anchor, rel = paste(parts[k:length(parts)], collapse = "/"))
}

# The files a write of `x` to `path` produces: one path, one per sink of a
# list (named paths, or "<sink>.tif" in a directory), or one per group.
.write_targets <- function(x, path) {
  if (S7::S7_inherits(x, LazyDatasetGroups)) {
    return(unlist(.group_paths(path, names(x@groups))))
  }
  if (is.list(x) && !S7::S7_inherits(x, LazyRaster) && !S7::S7_inherits(x, LazyDataset)) {
    return(unname(.sink_paths(path, names(x))))
  }
  path
}
