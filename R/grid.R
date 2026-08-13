# ---------------------------------------------------------------------------
# GridSpec: the spatial identity of a LazyRaster.
#
# CRS + affine transform + extent + dimensions + dtype. Every LazyRaster
# carries one. Binary ops require grid equality; mismatches are resolved
# via explicit `align()`, which injects a WarpNode.
#
# Locked conventions (decision register D1-D3, design/implementation-plan.md):
# - extent order is (xmin, ymin, xmax, ymax) everywhere in garry; vaster's
#   (xmin, xmax, ymin, ymax) order exists only behind `as_vaster_extent()`.
# - CRS is canonicalised to GDAL WKT at construction; fast equality is
#   string identity, semantic fallback is gdalraster::srs_is_same().
# - dtypes are anvl's vocabulary; promotion is XLA-style (float beats int;
#   f32 + i32 is f32, never R's f64).
# - Grids are north-up, unrotated: transform[3] == transform[5] == 0.
# ---------------------------------------------------------------------------

# -- dtype vocabulary and promotion -----------------------------------------

.garry_dtypes <- c(
  "f32",
  "f64",
  "i8",
  "i16",
  "i32",
  "i64",
  "u8",
  "u16",
  "u32",
  "u64",
  "pred"
)

.dtype_family <- function(dtype) {
  switch(substr(dtype, 1L, 1L), f = "float", i = "int", u = "uint", p = "pred")
}

.dtype_width <- function(dtype) {
  if (dtype == "pred") {
    return(1L)
  }
  as.integer(sub("^[fiu]", "", dtype))
}

#' Is `dtype` a member of garry's dtype vocabulary?
#'
#' The valid dtype strings are `"f32"`, `"f64"`, `"i8"`, `"i16"`,
#' `"i32"`, `"i64"`, `"u8"`, `"u16"`, `"u32"`, `"u64"`, and `"pred"`
#' (a boolean/predicate type).
#'
#' @param dtype A dtype string, e.g. `"f32"`.
#' @return `TRUE` or `FALSE`.
#' @export
dtype_valid <- function(dtype) {
  is.character(dtype) && length(dtype) == 1L && dtype %in% .garry_dtypes
}

#' Promote two dtypes for a binary operation.
#'
#' The promotion rules:
#' - float dominates: float op int/uint/pred keeps the float type;
#' - within a family the wider type wins;
#' - pred promotes to the other operand;
#' - signed op unsigned promotes to a signed type wide enough for both
#'   (u64 has no signed container, so it promotes to f64, following NumPy);
#' - `divide = TRUE` forces a float result: 32-bit-or-narrower integer
#'   inputs give f32, 64-bit integer inputs give f64.
#'
#' @param a,b dtype strings from the garry vocabulary.
#' @param divide Is the operation a division?
#' @return The promoted dtype string.
#' @export
dtype_promote <- function(a, b, divide = FALSE) {
  if (!dtype_valid(a)) {
    cli::cli_abort("invalid dtype: {.val {a}}")
  }
  if (!dtype_valid(b)) {
    cli::cli_abort("invalid dtype: {.val {b}}")
  }

  fa <- .dtype_family(a)
  fb <- .dtype_family(b)
  wa <- .dtype_width(a)
  wb <- .dtype_width(b)

  out <- if (a == b) {
    a
  } else if (fa == "pred") {
    b
  } else if (fb == "pred") {
    a
  } else if (fa == "float" && fb == "float") {
    if (wa >= wb) a else b
  } else if (fa == "float") {
    a
  } else if (fb == "float") {
    b
  } else if (fa == fb) {
    if (wa >= wb) a else b
  } else {
    # signed vs unsigned
    uw <- if (fa == "uint") wa else wb
    sw <- if (fa == "int") wa else wb
    if (uw >= 64L) {
      "f64"
    } else {
      paste0("i", min(64L, max(sw, uw * 2L)))
    }
  }

  if (divide && .dtype_family(out) != "float") {
    out <- if (out != "pred" && .dtype_width(out) >= 64L) "f64" else "f32"
  }
  out
}

# -- CRS canonicalisation ----------------------------------------------------

# Memoised srs_to_wkt: GridSpecs are created per IR node, so avoid a PROJ
# lookup on every construction.
.crs_cache <- new.env(parent = emptyenv())

.canon_crs <- function(crs) {
  hit <- .crs_cache[[crs]]
  if (!is.null(hit)) {
    return(hit)
  }
  wkt <- gdalraster::srs_to_wkt(crs)
  if (!nzchar(wkt)) {
    cli::cli_abort("cannot interpret CRS: {.val {crs}}")
  }
  .crs_cache[[crs]] <- wkt
  wkt
}

#' Are two CRS strings the same reference system?
#'
#' Fast path: identity of canonical WKT. Fallback: PROJ semantic
#' comparison via gdalraster::srs_is_same().
#'
#' @param a,b CRS strings (any GDAL-interpretable form).
#' @return `TRUE` or `FALSE`.
#' @export
crs_equal <- function(a, b) {
  identical(a, b) || gdalraster::srs_is_same(a, b)
}

# -- GridSpec -----------------------------------------------------------------

# Allowed dim names, in default assignment order (decision D7).
.dim_names <- c("x", "y", "t", "band")

#' Spatial grid specification.
#'
#' The constructor canonicalises `crs` to GDAL WKT, so two GridSpecs built
#' from "EPSG:4326" and the equivalent proj4/WKT string compare equal.
#'
#' @param crs CRS string in any GDAL-interpretable form.
#' @param transform GDAL geotransform, length 6, north-up.
#' @param extent Numeric length 4: xmin, ymin, xmax, ymax.
#' @param dims Integer dimensions: nx, ny (optionally nt, nb).
#' @param labels Optional named list of character vectors labelling the
#'   non-spatial dims (slice dates on `t`, band names on `band`); each
#'   length-matched to its dim. Metadata only: planning ignores labels.
#' @param dtype dtype string from the garry vocabulary.
#' @return A `GridSpec`.
#' @export
GridSpec <- S7::new_class(
  "GridSpec",
  properties = list(
    crs = S7::class_character,
    transform = S7::class_numeric, # length 6 (GDAL geotransform)
    extent = S7::class_numeric, # xmin, ymin, xmax, ymax
    dims = S7::class_integer, # nx, ny [, nt, nb]
    dtype = S7::class_character, # anvl-aligned: "f32", "i16", ...
    # Optional per-axis labels for the NON-SPATIAL dims (slice dates on
    # t, band names on band): a named list of character vectors, each
    # length-matched to its dim. Labels are METADATA, not data: no
    # planner pass reads them (grid_equal ignores them), so planning
    # stays grid-identity-trivial while label selection, labelled
    # output and dt-aware scans become expressible.
    labels = S7::class_list
  ),
  constructor = function(crs, transform, extent, dims, dtype, labels = list()) {
    if (!is.character(crs) || length(crs) != 1L || !nzchar(crs)) {
      cli::cli_abort("{.arg crs} must be a single non-empty string")
    }
    nm <- names(dims) # as.integer() strips names; keep them
    dims <- as.integer(dims)
    names(dims) <- if (is.null(nm)) .dim_names[seq_along(dims)] else nm
    S7::new_object(
      S7::S7_object(),
      crs = .canon_crs(crs),
      transform = as.numeric(transform),
      extent = as.numeric(extent),
      dims = dims,
      dtype = dtype,
      labels = labels
    )
  },
  validator = function(self) {
    if (length(self@labels)) {
      lnm <- names(self@labels)
      if (
        is.null(lnm) ||
          anyDuplicated(lnm) ||
          !all(lnm %in% setdiff(names(self@dims), c("x", "y")))
      ) {
        return(paste0(
          "`labels` must be named by non-spatial dims ",
          "present in `dims`"
        ))
      }
      for (nm2 in lnm) {
        v <- self@labels[[nm2]]
        if (!is.character(v) || length(v) != self@dims[[nm2]]) {
          return(.glue(
            "`labels${nm2}` must be a character vector of length ",
            "{self@dims[[nm2]]}"
          ))
        }
      }
    }
    if (length(self@transform) != 6L) {
      return("`transform` must be length 6 (GDAL geotransform)")
    }
    if (length(self@extent) != 4L) {
      return("`extent` must be length 4 (xmin, ymin, xmax, ymax)")
    }
    if (
      self@extent[1L] >= self@extent[3L] ||
        self@extent[2L] >= self@extent[4L]
    ) {
      return("`extent` must satisfy xmin < xmax and ymin < ymax")
    }
    if (
      length(self@dims) < 2L || length(self@dims) > 4L || any(self@dims <= 0L)
    ) {
      return("`dims` must have 2-4 positive entries")
    }
    nm <- names(self@dims)
    if (
      is.null(nm) ||
        !identical(nm[1:2], c("x", "y")) ||
        anyDuplicated(nm) ||
        !all(nm %in% .dim_names)
    ) {
      return(paste0(
        "`dims` must be named: first two \"x\", \"y\"; ",
        "extras from \"t\", \"band\""
      ))
    }
    if (!dtype_valid(self@dtype)) {
      return(paste0(
        "`dtype` must be one of: ",
        paste(.garry_dtypes, collapse = ", ")
      ))
    }
    gt <- self@transform
    if (gt[3L] != 0 || gt[5L] != 0) {
      return(
        "rotated grids are not supported (transform[3] and transform[5] must be 0)"
      )
    }
    if (gt[2L] <= 0 || gt[6L] >= 0) {
      return("grids must be north-up (transform[2] > 0, transform[6] < 0)")
    }
    # Coherence: extent must be derivable from transform + dim.
    nx <- self@dims[1L]
    ny <- self@dims[2L]
    tol <- 1e-6 * max(abs(gt[2L]), abs(gt[6L]))
    derived <- c(
      gt[1L], # xmin
      gt[4L] + ny * gt[6L], # ymin
      gt[1L] + nx * gt[2L], # xmax
      gt[4L]
    ) # ymax
    if (any(abs(derived - self@extent) > tol)) {
      return(.glue(
        "`extent` does not agree with `transform` + `dim` ",
        "(expected [{paste(format(derived), collapse = ', ')}])"
      ))
    }
    NULL
  }
)

#' Convenience constructor: derive the transform from extent + dims (or res).
#'
#' Give the pixel grid either directly as `dims` (nx, ny) or as `res` (pixel
#' size), from which `dims` is derived and the `extent` snapped to a whole number
#' of pixels. Exactly one of the two.
#'
#' @param crs CRS string in any GDAL-interpretable form.
#' @param extent Numeric length 4: xmin, ymin, xmax, ymax.
#' @param dims Integer dimensions `c(nx, ny)`. Provide this OR `res`, not both.
#' @param dtype dtype string from the garry vocabulary.
#' @param res Pixel resolution in the units of `crs`: a scalar (square pixels) or
#'   `c(xres, yres)`. Derives `dims` from `extent` and snaps `extent` to a whole
#'   number of pixels (anchored at the top-left, so the resolution is exactly
#'   `res`). Provide this OR `dims`, not both.
#' @return A `GridSpec`.
#' @seealso [grid_from_bbox()] and [grid_from_src()], the higher-level
#'   constructors that derive a grid from an area of interest;
#'   [GridSpec()], the underlying class constructor.
#' @export
grid_spec <- function(crs, extent, dims = NULL, dtype = "f32", res = NULL) {
  extent <- as.numeric(extent)
  if (is.null(dims) == is.null(res)) {
    cli::cli_abort(c(
      "Provide exactly one of {.arg dims} or {.arg res}.",
      "i" = "{.arg dims} sets the pixel grid directly; {.arg res} derives it from {.arg extent}."
    ))
  }
  if (!is.null(res)) {
    res <- rep_len(as.numeric(res), 2L) # scalar (square) or c(xres, yres)
    if (any(res <= 0)) {
      cli::cli_abort("{.arg res} must be positive.")
    }
    dims <- c(
      round((extent[3L] - extent[1L]) / res[1L]),
      round((extent[4L] - extent[2L]) / res[2L])
    )
    if (any(dims < 1L)) {
      cli::cli_abort(
        "{.arg res} is coarser than {.arg extent}; no whole pixels fit."
      )
    }
    # Snap the extent to a whole number of `res` pixels, anchored at the
    # top-left (xmin, ymax), so the derived resolution is exactly `res`.
    extent <- c(
      extent[1L],
      extent[4L] - dims[2L] * res[2L],
      extent[1L] + dims[1L] * res[1L],
      extent[4L]
    )
  }
  dims <- as.integer(dims)
  dx <- (extent[3L] - extent[1L]) / dims[1L]
  dy <- (extent[4L] - extent[2L]) / dims[2L]
  GridSpec(
    crs = crs,
    transform = c(extent[1L], dx, 0, extent[4L], 0, -dy),
    extent = extent,
    dims = dims,
    dtype = dtype
  )
}

# -- Accessors (nothing outside this file indexes @extent positionally) ------

#' Grid extent and resolution accessors.
#'
#' @param x A `GridSpec` or a `LazyRaster` (which forwards to its grid).
#' @param ... Passed to methods.
#' @return A numeric scalar (`xmin`, `ymin`, `xmax`, `ymax`) or a length-2
#'   numeric `c(xres, yres)` for `res`.
#' @name grid-accessors
NULL

#' @rdname grid-accessors
#' @export
xmin <- S7::new_generic("xmin", "x")
S7::method(xmin, GridSpec) <- function(x) x@extent[1L]

#' @rdname grid-accessors
#' @export
ymin <- S7::new_generic("ymin", "x")
S7::method(ymin, GridSpec) <- function(x) x@extent[2L]

#' @rdname grid-accessors
#' @export
xmax <- S7::new_generic("xmax", "x")
S7::method(xmax, GridSpec) <- function(x) x@extent[3L]

#' @rdname grid-accessors
#' @export
ymax <- S7::new_generic("ymax", "x")
S7::method(ymax, GridSpec) <- function(x) x@extent[4L]

#' @rdname grid-accessors
#' @export
res <- S7::new_generic("res", "x")
S7::method(res, GridSpec) <- function(x) {
  c(x@transform[2L], -x@transform[6L])
}

#' Reorder a garry extent for vaster calls.
#'
#' garry orders extents (xmin, ymin, xmax, ymax); vaster expects
#' (xmin, xmax, ymin, ymax). This helper performs that reordering, so
#' extents cross the package boundary in one place.
#'
#' @param x A `GridSpec` or a length-4 garry-order extent.
#' @return Length-4 numeric in vaster order.
#' @keywords internal
#' @export
as_vaster_extent <- function(x) {
  ext <- if (S7::S7_inherits(x, GridSpec)) x@extent else as.numeric(x)
  stopifnot(length(ext) == 4L)
  ext[c(1L, 3L, 2L, 4L)]
}

# -- Equality -----------------------------------------------------------------

#' Structural equality of two grids (geometry only, not dtype).
#'
#' @param a,b `GridSpec` objects.
#' @param tol Numeric tolerance for transform/extent comparison.
#' @return `TRUE` or `FALSE`.
#' @seealso [grid_diff()], which describes how two grids differ.
#' @export
grid_equal <- function(a, b, tol = 1e-9) {
  crs_equal(a@crs, b@crs) &&
    all(abs(a@transform - b@transform) < tol) &&
    all(abs(a@extent - b@extent) < tol) &&
    length(a@dims) == length(b@dims) &&
    all(a@dims == b@dims)
}

#' Describe how two grids differ.
#'
#' The diagnostic companion to [grid_equal()]: names the FIRST differing
#' component (CRS, resolution, extent offset in pixels, dims) so a
#' "grids differ" abort tells the user what to fix rather than only that
#' something is wrong. Embedded in every alignment error.
#'
#' @param a,b `GridSpec` objects.
#' @param tol Numeric tolerance, as in [grid_equal()].
#' @return A single character description; `"grids are equal"` when
#'   [grid_equal()] holds.
#' @export
grid_diff <- function(a, b, tol = 1e-9) {
  if (!crs_equal(a@crs, b@crs)) {
    return("CRS differs")
  }
  ra <- c(a@transform[[2L]], -a@transform[[6L]])
  rb <- c(b@transform[[2L]], -b@transform[[6L]])
  if (any(abs(ra - rb) > tol)) {
    return(.glue(
      "resolution differs: {format(ra[[1L]])} x {format(ra[[2L]])}",
      " vs {format(rb[[1L]])} x {format(rb[[2L]])}"
    ))
  }
  if (any(abs(a@extent - b@extent) > tol)) {
    off <- (b@extent - a@extent) / c(ra[[1L]], ra[[2L]], ra[[1L]], ra[[2L]])
    return(.glue(
      "extents differ by {formatC(max(abs(off[c(1L, 3L)])), format = 'g', digits = 3, width = 1)}",
      " px in x, {formatC(max(abs(off[c(2L, 4L)])), format = 'g', digits = 3, width = 1)} px in y"
    ))
  }
  if (length(a@dims) != length(b@dims) || any(a@dims != b@dims)) {
    return(.glue(
      "dims differ: ({paste(a@dims, collapse = ',')}) vs ",
      "({paste(b@dims, collapse = ',')})"
    ))
  }
  "grids are equal"
}

# Internal: same CRS, spatial dims and affine transform; non-spatial
# dims and dtype ignored (a stack and its median share spatial
# geometry). Used by the planner's stage-merge pass.
.spatial_equal <- function(a, b, tol = 1e-9) {
  crs_equal(a@crs, b@crs) &&
    all(abs(a@transform - b@transform) < tol) &&
    identical(unname(a@dims[c("x", "y")]), unname(b@dims[c("x", "y")]))
}

# Internal: same grid, different dtype (dtype promotion on binary ops,
# float promotion on reductions and nodata sources).
.grid_retype <- function(grid, dtype) {
  if (identical(grid@dtype, dtype)) {
    return(grid)
  }
  GridSpec(
    crs = grid@crs,
    transform = grid@transform,
    extent = grid@extent,
    dims = grid@dims,
    dtype = dtype,
    labels = grid@labels
  )
}

# Internal: same grid with one non-spatial axis (re)labelled. NULL
# labels (or a length mismatch, e.g. unnamed layers) leave the grid
# unchanged rather than erroring: labels are best-effort metadata.
.grid_relabel <- function(grid, dim, labels) {
  if (
    is.null(labels) ||
      !dim %in% names(grid@dims) ||
      length(labels) != grid@dims[[dim]] ||
      !all(nzchar(labels))
  ) {
    return(grid)
  }
  lb <- grid@labels
  lb[[dim]] <- as.character(labels)
  GridSpec(
    crs = grid@crs,
    transform = grid@transform,
    extent = grid@extent,
    dims = grid@dims,
    dtype = grid@dtype,
    labels = lb
  )
}

# Internal: the labels of a single-layer-axis grid, for labelled output
# ((t,y,x) or (band,y,x) results): the one non-spatial dim's labels, or
# NULL when absent/ambiguous.
.grid_layer_labels <- function(grid) {
  nsd <- setdiff(names(grid@dims), c("x", "y"))
  if (length(nsd) != 1L) {
    return(NULL)
  }
  grid@labels[[nsd]]
}
