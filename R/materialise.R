#' @include dataset.R lazy_raster.R collect.R
#' @keywords internal
NULL

# Refuse (or clear, with overwrite = TRUE) an existing .vrt/.bin pair.
.mat_check_clear <- function(path, overwrite) {
  bin <- sub("\\.vrt$", ".bin", path)
  hit <- c(path, bin)[file.exists(c(path, bin))]
  if (length(hit) && !overwrite) {
    cli::cli_abort(c(
      "target already exists: {.path {hit[[1L]]}}.",
      "i" = "pass {.code overwrite = TRUE} to replace it (the existing
             file may hold pixels from an older graph)"
    ))
  }
  unlink(c(path, bin))
}

#' Materialise a lazy object locally and stay lazy.
#'
#' The checkpoint verb (dbplyr's `compute()` for rasters): execute the
#' current graph, write the results to local raw-BSQ cubes (`.vrt` +
#' `.bin`, a format any GDAL tool reads and garry re-reads much faster
#' than tiled GeoTIFF), and return the SAME KIND of lazy object rebuilt
#' over the local files. Everything downstream continues unchanged;
#' nothing upstream (network reads, warps, masking, model inference)
#' runs again.
#'
#' A `LazyDataset` writes one multiband cube per time slice through a
#' single multi-sink plan (all slices' reads drain together), carrying
#' band names, slice dates, and the `mask_asset` into the rebuilt
#' dataset; ragged bands (a band missing some slices) survive. A
#' `LazyRaster` writes one cube and reopens it. A computed raster
#' cannot be warped directly, so materialise-then-rewarp is the
#' supported route: `align(materialise(x, dir), grid)`.
#'
#' Files land at `dir/name-<slice>.vrt` (dataset) or `dir/name.vrt`
#' (raster). Existing files are refused unless `overwrite = TRUE`:
#' the graph may have changed since they were written, and silently
#' reusing stale pixels is the failure mode a checkpoint must not have.
#'
#' `dir` defaults to a fresh unique directory under the session's
#' [tempdir()], announced by a message: convenient, but session-scoped
#' (the files vanish when R exits), and every call writes a NEW copy,
#' so repeated interactive re-runs accumulate until the session ends.
#' For large cubes, or to keep or reuse a checkpoint, give a real
#' directory (note some systems mount `/tmp` in RAM).
#'
#' @param x A `LazyDataset`, a `LazyRaster`, or a named list of
#'   `LazyRaster`s (multi-export: one execution, one cube per name).
#' @param dir Directory for the cubes (created if missing); default: a
#'   unique session-temporary directory.
#' @param name File-name stem (default `"garry"`).
#' @param nodata Optional sentinel for the written files, as in
#'   [write_tif()].
#' @param overwrite Replace existing files at the target paths?
#' @param distributed As in [collect()].
#' @return A lazy object of the same class as `x`, reading the local
#'   cubes; for a named list, a named list of `LazyRaster`s (one per
#'   sink, same names).
#' @seealso [collect()] to execute and return the result in the R
#'   session; [write_tif()] to execute and stream to a GeoTIFF.
#' @export
materialise <- function(
  x,
  dir = NULL,
  name = "garry",
  nodata = NULL,
  overwrite = FALSE,
  distributed = garry_daemons_set()
) {
  if (is.null(dir)) {
    dir <- tempfile("materialise-")
    cli::cli_inform("materialising to {.path {dir}} (session-temporary)")
  }
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  if (S7::S7_inherits(x, LazyRaster)) {
    path <- file.path(dir, paste0(name, ".vrt"))
    .mat_check_clear(path, overwrite)
    .collect_impl(x, path = path, nodata = nodata, distributed = distributed)
    return(lazy_source(path))
  }
  if (is.list(x) && !S7::S7_inherits(x, LazyDataset)) {
    # Multi-export: several lazy rasters checkpointed in ONE execution
    # (shared upstream runs once), one cube per sink, named by the list
    # names under `name`. The raw-cube twin of write_tif()'s named-list
    # form; `name` is a prefix here ("<name>-<sink>.vrt").
    if (is.null(names(x)) || any(!nzchar(names(x))) || anyDuplicated(names(x))) {
      cli::cli_abort("a list `x` must have unique, non-empty names (one per sink).")
    }
    if (!all(vapply(x, function(e) S7::S7_inherits(e, LazyRaster), logical(1)))) {
      cli::cli_abort("every element of a list `x` must be a LazyRaster.")
    }
    paths <- stats::setNames(
      file.path(dir, paste0(name, "-", names(x), ".vrt")),
      names(x)
    )
    for (p in paths) .mat_check_clear(p, overwrite)
    .collect_impl(x, path = paths, nodata = nodata, distributed = distributed)
    return(lapply(paths, lazy_source))
  }
  .assert_class(x, LazyDataset, "LazyDataset")

  slices <- unique(unlist(lapply(x@bands, names), use.names = FALSE))
  # Single-slice dataset: a composite (reduce_over drops the time axis), or
  # the file form of lazy_dataset(). There are no dates to key cubes by and
  # none are needed -- write ONE cube, a band per dataset band.
  if (is.null(slices) && all(vapply(x@bands, length, integer(1)) == 1L)) {
    path <- file.path(dir, paste0(name, ".vrt"))
    .mat_check_clear(path, overwrite)
    bn <- names(x@bands)
    layers <- lapply(x@bands, `[[`, 1L)
    sink <- if (length(layers) == 1L) {
      layers[[1L]]
    } else {
      lazy_stack(stats::setNames(layers, bn), along = "band")
    }
    .collect_impl(
      sink,
      path = path,
      nodata = nodata,
      distributed = distributed,
      band_names = bn
    )
    bands <- stats::setNames(
      lapply(seq_along(bn), function(i) lazy_source(path, band = i)),
      bn
    )
    return(as_dataset(
      bands,
      mask_asset = if (length(x@mask_asset)) x@mask_asset
    ))
  }
  if (is.null(slices) || !all(nzchar(slices))) {
    cli::cli_abort(c(
      "the dataset's slices must be named (dates) to materialise.",
      "i" = "unnamed layers cannot be matched back into a dataset"
    ))
  }
  slices <- sort(slices)

  # one sink per slice: the bands PRESENT on that date, stacked in the
  # dataset's band order (ragged bands shrink their dates' cubes)
  order_of <- lapply(stats::setNames(nm = slices), function(nm) {
    names(x@bands)[vapply(x@bands, function(b) nm %in% names(b), logical(1))]
  })
  sinks <- lapply(stats::setNames(nm = slices), function(nm) {
    layers <- lapply(order_of[[nm]], function(b) x@bands[[b]][[nm]])
    if (length(layers) == 1L) {
      layers[[1L]]
    } else {
      lazy_stack(stats::setNames(layers, order_of[[nm]]), along = "band")
    }
  })
  paths <- stats::setNames(
    file.path(dir, paste0(name, "-", slices, ".vrt")),
    slices
  )
  for (p in paths) {
    .mat_check_clear(p, overwrite)
  }

  .collect_impl(
    sinks,
    path = paths,
    nodata = nodata,
    distributed = distributed,
    band_names = order_of
  )

  bands <- lapply(stats::setNames(nm = names(x@bands)), function(b) {
    have <- slices[vapply(order_of, function(o) b %in% o, logical(1))]
    stats::setNames(
      lapply(have, function(nm) {
        lazy_source(paths[[nm]], band = match(b, order_of[[nm]]))
      }),
      have
    )
  })
  as_dataset(bands, mask_asset = if (length(x@mask_asset)) x@mask_asset)
}
