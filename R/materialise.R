#' @include dataset.R lazy_raster.R collect.R
#' @keywords internal
NULL

# Refuse (or clear, with overwrite = TRUE) an existing .vrt/.bin pair or
# GeoTIFF.
.mat_check_clear <- function(path, overwrite) {
  bin <- sub("\\.vrt$", ".bin", path)
  hit <- unique(c(path, bin)[file.exists(c(path, bin))])
  if (length(hit) && !overwrite) {
    cli::cli_abort(c(
      "target already exists: {.path {hit[[1L]]}}.",
      "i" = "pass {.code overwrite = TRUE} to replace it (the existing
             file may hold pixels from an older graph)"
    ))
  }
  unlink(c(path, bin))
}

# Checkpoint file for a sink: a raw-BSQ cube for float data, a GeoTIFF for
# integer data (raw cubes hold f32/f64 only, and widening would change the
# dtype the rest of the pipeline sees).
.mat_path <- function(dir, stem, dtype) {
  ext <- if (.dtype_family(dtype) == "float") ".vrt" else ".tif"
  file.path(dir, paste0(stem, ext))
}

# Reopen a checkpointed LazyRaster with the shape it was written with: one
# file band per element of its single outer axis, stacked back along that
# axis with its labels.
.mat_reopen <- function(path, grid) {
  outer <- grid@dims[setdiff(names(grid@dims), c("x", "y"))]
  if (!length(outer)) {
    return(lazy_source(path))
  }
  ax <- names(outer)
  layers <- lapply(seq_len(outer[[1L]]), function(i) lazy_source(path, band = i))
  names(layers) <- grid@labels[[ax]]
  lazy_stack(layers, along = ax)
}

# A LazyRaster materialise can write and reopen: at most one outer axis.
.mat_check_raster <- function(x, arg = "x") {
  outer <- setdiff(names(x@grid@dims), c("x", "y"))
  if (length(outer) > 1L) {
    cli::cli_abort(c(
      "{.arg {arg}} has more than one outer axis ({.val {outer}}).",
      "i" = "Reduce or select along one of them first, or build a dataset."
    ), call = rlang::caller_env())
  }
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
#' supported route: `align_to(materialise(x, dir), grid)`.
#'
#' Files land at `dir/name-<slice>.vrt` (dataset) or `dir/name.vrt`
#' (raster); integer-typed data is written as `.tif` instead, since raw
#' cubes hold floats only. A raster with a `t` or `band` axis comes back
#' stacked along that axis with its labels. Existing files are refused unless `overwrite = TRUE`:
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
  if (S7::S7_inherits(x, LazyRaster)) {
    .mat_check_raster(x)
  }
  if (is.null(dir)) {
    dir <- tempfile("materialise-")
    cli::cli_inform("materialising to {.path {dir}} (session-temporary)")
  }
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  if (S7::S7_inherits(x, LazyRaster)) {
    path <- .mat_path(dir, name, x@grid@dtype)
    .mat_check_clear(path, overwrite)
    .collect_impl(x, path = path, nodata = nodata, distributed = distributed)
    return(.mat_reopen(path, x@grid))
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
    for (nm in names(x)) .mat_check_raster(x[[nm]], arg = nm)
    paths <- vapply(
      names(x),
      function(nm) .mat_path(dir, paste0(name, "-", nm), x[[nm]]@grid@dtype),
      character(1)
    )
    for (p in paths) .mat_check_clear(p, overwrite)
    .collect_impl(x, path = paths, nodata = nodata, distributed = distributed)
    return(Map(.mat_reopen, paths, lapply(x, function(e) e@grid)))
  }
  .assert_class(x, LazyDataset, "LazyDataset")

  slices <- unique(unlist(lapply(x@bands, names), use.names = FALSE))
  # Single-slice dataset: a composite (reduce_over drops the time axis), or
  # the file form of lazy_dataset(). There are no dates to key cubes by and
  # none are needed -- write ONE cube, a band per dataset band.
  if (is.null(slices) && all(vapply(x@bands, length, integer(1)) == 1L)) {
    bn <- names(x@bands)
    layers <- lapply(x@bands, `[[`, 1L)
    sink <- if (length(layers) == 1L) {
      layers[[1L]]
    } else {
      lazy_stack(stats::setNames(layers, bn), along = "band")
    }
    path <- .mat_path(dir, name, sink@grid@dtype)
    .mat_check_clear(path, overwrite)
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
  paths <- vapply(
    slices,
    function(nm) {
      .mat_path(dir, paste0(name, "-", nm), sinks[[nm]]@grid@dtype)
    },
    character(1)
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
