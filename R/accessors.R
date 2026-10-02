#' @include dataset.R lazy_raster.R
NULL

# ---------------------------------------------------------------------------
# Base-R accessors for lazy objects, so user code and the vignettes need not
# reach into `@` slots.
# ---------------------------------------------------------------------------

# The GridSpec behind a grid, raster or dataset.
.grid_of <- function(x, arg = "x") {
  if (S7::S7_inherits(x, GridSpec)) {
    return(x)
  }
  if (S7::S7_inherits(x, LazyRaster)) {
    return(x@grid)
  }
  if (S7::S7_inherits(x, LazyDataset)) {
    return(.ds_grid(x))
  }
  cli::cli_abort(
    "{.arg {arg}} must be a {.cls GridSpec}, {.cls LazyRaster} or {.cls LazyDataset}.",
    call = rlang::caller_env()
  )
}

#' Grid extent, resolution and CRS
#'
#' Read the georeferencing of a grid, a lazy raster or a lazy dataset.
#'
#' @param x A `GridSpec`, `LazyRaster` or `LazyDataset`.
#' @return `grid_bbox()`: a named numeric `c(xmin, ymin, xmax, ymax)`.
#'   `grid_res()`: a named numeric `c(x, y)` of positive cell sizes.
#'   `grid_crs()`: the CRS as a string.
#' @name grid-accessors
#' @examples
#' g <- grid_spec(c(0, 0, 100, 50), res = 10, crs = "EPSG:3857")
#' grid_bbox(g)
#' grid_res(g)
#' grid_crs(g)
NULL

#' @rdname grid-accessors
#' @export
grid_bbox <- function(x) {
  stats::setNames(.grid_of(x)@extent, c("xmin", "ymin", "xmax", "ymax"))
}

#' @rdname grid-accessors
#' @export
grid_res <- function(x) {
  gt <- .grid_of(x)@transform
  c(x = gt[[2L]], y = -gt[[6L]])
}

#' @rdname grid-accessors
#' @export
grid_crs <- function(x) .grid_of(x)@crs

# Dims in collect() order: rows (y), columns (x), then the non-spatial axes.
.collect_dims <- function(g) {
  d <- g@dims
  c(d[c("y", "x")], d[setdiff(names(d), c("x", "y"))])
}

#' Dimensions of a lazy raster
#'
#' The shape `collect()` returns: rows (`y`), columns (`x`), then any
#' non-spatial axes (`t`, `band`), named.
#'
#' @param x A `LazyRaster` or `GridSpec`.
#' @return A named integer vector.
#' @name lazy-dim
#' @examples
#' g <- grid_spec(c(0, 0, 100, 50), res = 10, crs = "EPSG:3857")
#' dim(g)
NULL

S7::method(dim, LazyRaster) <- function(x) .collect_dims(x@grid)
S7::method(dim, GridSpec) <- function(x) .collect_dims(x)

#' Bands of a lazy dataset
#'
#' `names()` lists a dataset's bands, including any QA/mask band, and
#' `length()` counts them. `ds$B04` is `ds[["B04"]]`, and
#' `ds$ndvi <- value` is `ds[["ndvi"]] <- value`.
#'
#' @param x A `LazyDataset`.
#' @param name A band name.
#' @param value A `LazyRaster` (or a list of per-slice `LazyRaster`s) on the
#'   dataset's grid.
#' @return `names()`: a character vector. `length()`: an integer. `$`: a
#'   `LazyRaster`. `$<-`: the updated `LazyDataset`.
#' @name dataset-bands
NULL

S7::method(names, LazyDataset) <- function(x) names(x@bands)
S7::method(length, LazyDataset) <- function(x) length(x@bands)
S7::method(`$`, LazyDataset) <- function(x, name) x[[name]]

# Plain S3 registration, as for `[[<-` (see .lazy_dataset_assign).
#' @rawNamespace S3method("$<-", "garry::LazyDataset", .lazy_dataset_dollar_assign)
.lazy_dataset_dollar_assign <- function(x, name, value) {
  .lazy_dataset_assign(x, name, value)
}

#' Time labels of a lazy object
#'
#' The labels on the `t` axis: one per slice, typically acquisition dates
#' or the period labels [group_by_time()] assigns.
#'
#' @param x A `LazyRaster`, `GridSpec` or `LazyDataset`.
#' @return A character vector, or `NULL` when there is no labelled `t` axis.
#'   For a `LazyDataset` whose value bands carry different labels, a list
#'   named by band.
#' @export
#' @examples
#' g <- grid_spec(c(0, 0, 100, 50), res = 10, crs = "EPSG:3857")
#' time_labels(g)
time_labels <- function(x) {
  if (S7::S7_inherits(x, LazyDataset)) {
    bands <- .ds_value_bands(x)
    labs <- lapply(stats::setNames(nm = bands), function(b) {
      time_labels(x[[b]]) %||% names(x@bands[[b]])
    })
    labs <- labs[!vapply(labs, is.null, logical(1))]
    if (!length(labs)) {
      return(NULL)
    }
    uniq <- unique(unname(labs))
    return(if (length(uniq) == 1L) uniq[[1L]] else labs)
  }
  if (S7::S7_inherits(x, LazyRaster)) {
    x <- x@grid
  }
  .assert_class(x, GridSpec, "LazyRaster, GridSpec or LazyDataset")
  x@labels$t
}
