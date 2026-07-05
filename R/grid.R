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

.garry_dtypes <- c("f32", "f64",
                   "i8", "i16", "i32", "i64",
                   "u8", "u16", "u32", "u64",
                   "pred")

.dtype_family <- function(dtype) {
  switch(substr(dtype, 1L, 1L), f = "float", i = "int", u = "uint", p = "pred")
}

.dtype_width <- function(dtype) {
  if (dtype == "pred") return(1L)
  as.integer(sub("^[fiu]", "", dtype))
}

#' Is `dtype` a member of garry's (anvl-aligned) dtype vocabulary?
#'
#' @param dtype A dtype string, e.g. `"f32"`.
#' @return `TRUE` or `FALSE`.
#' @export
dtype_valid <- function(dtype) {
  is.character(dtype) && length(dtype) == 1L && dtype %in% .garry_dtypes
}

#' Promote two dtypes for a binary operation.
#'
#' XLA-style rules, locked by decision D3:
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
  if (!dtype_valid(a)) stop("invalid dtype: ", a)
  if (!dtype_valid(b)) stop("invalid dtype: ", b)

  fa <- .dtype_family(a); fb <- .dtype_family(b)
  wa <- .dtype_width(a);  wb <- .dtype_width(b)

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
    if (uw >= 64L) "f64"
    else paste0("i", min(64L, max(sw, uw * 2L)))
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
  if (!is.null(hit)) return(hit)
  wkt <- gdalraster::srs_to_wkt(crs)
  if (!nzchar(wkt)) stop("cannot interpret CRS: ", crs)
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

#' Spatial grid specification.
#'
#' The constructor canonicalises `crs` to GDAL WKT, so two GridSpecs built
#' from "EPSG:4326" and the equivalent proj4/WKT string compare equal.
#'
#' @param crs CRS string in any GDAL-interpretable form.
#' @param transform GDAL geotransform, length 6, north-up.
#' @param extent Numeric length 4: xmin, ymin, xmax, ymax.
#' @param dims Integer dimensions: nx, ny (optionally nt, nb).
#' @param dtype dtype string from the garry vocabulary.
#' @return A `GridSpec`.
#' @export
GridSpec <- S7::new_class(
  "GridSpec",
  properties = list(
    crs       = S7::class_character,
    transform = S7::class_numeric,   # length 6 (GDAL geotransform)
    extent    = S7::class_numeric,   # xmin, ymin, xmax, ymax
    dims       = S7::class_integer,   # nx, ny [, nt, nb]
    dtype     = S7::class_character  # anvl-aligned: "f32", "i16", ...
  ),
  constructor = function(crs, transform, extent, dims, dtype) {
    if (!is.character(crs) || length(crs) != 1L || !nzchar(crs))
      stop("`crs` must be a single non-empty string")
    S7::new_object(
      S7::S7_object(),
      crs       = .canon_crs(crs),
      transform = as.numeric(transform),
      extent    = as.numeric(extent),
      dims      = as.integer(dims),
      dtype     = dtype
    )
  },
  validator = function(self) {
    if (length(self@transform) != 6L)
      return("`transform` must be length 6 (GDAL geotransform)")
    if (length(self@extent) != 4L)
      return("`extent` must be length 4 (xmin, ymin, xmax, ymax)")
    if (self@extent[1L] >= self@extent[3L] ||
        self@extent[2L] >= self@extent[4L])
      return("`extent` must satisfy xmin < xmax and ymin < ymax")
    if (length(self@dims) < 2L || any(self@dims <= 0L))
      return("`dim` must have at least two positive entries (nx, ny)")
    if (!dtype_valid(self@dtype))
      return(paste0("`dtype` must be one of: ",
                    paste(.garry_dtypes, collapse = ", ")))
    gt <- self@transform
    if (gt[3L] != 0 || gt[5L] != 0)
      return("rotated grids are not supported (transform[3] and transform[5] must be 0)")
    if (gt[2L] <= 0 || gt[6L] >= 0)
      return("grids must be north-up (transform[2] > 0, transform[6] < 0)")
    # Coherence: extent must be derivable from transform + dim.
    nx <- self@dims[1L]; ny <- self@dims[2L]
    tol <- 1e-6 * max(abs(gt[2L]), abs(gt[6L]))
    derived <- c(gt[1L],                 # xmin
                 gt[4L] + ny * gt[6L],   # ymin
                 gt[1L] + nx * gt[2L],   # xmax
                 gt[4L])                 # ymax
    if (any(abs(derived - self@extent) > tol))
      return(sprintf(
        "`extent` does not agree with `transform` + `dim` (expected [%s])",
        paste(format(derived), collapse = ", ")))
    NULL
  }
)

#' Convenience constructor: derive the transform from extent + dims.
#'
#' @param crs CRS string in any GDAL-interpretable form.
#' @param extent Numeric length 4: xmin, ymin, xmax, ymax.
#' @param dims Integer dimensions: nx, ny.
#' @param dtype dtype string from the garry vocabulary.
#' @return A `GridSpec`.
#' @export
grid_spec <- function(crs, extent, dims, dtype = "f32") {
  dims <- as.integer(dims)
  dx <- (extent[3L] - extent[1L]) / dims[1L]
  dy <- (extent[4L] - extent[2L]) / dims[2L]
  GridSpec(
    crs       = crs,
    transform = c(extent[1L], dx, 0, extent[4L], 0, -dy),
    extent    = extent,
    dims      = dims,
    dtype     = dtype
  )
}

# -- Accessors (nothing outside this file indexes @extent positionally) ------

#' Grid extent and resolution accessors.
#'
#' @param x A `GridSpec`.
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
#' garry: (xmin, ymin, xmax, ymax); vaster: (xmin, xmax, ymin, ymax).
#' This helper is the ONLY sanctioned reorder point (decision D1).
#'
#' @param x A `GridSpec` or a length-4 garry-order extent.
#' @return Length-4 numeric in vaster order.
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
#' @export
grid_equal <- function(a, b, tol = 1e-9) {
  crs_equal(a@crs, b@crs) &&
    all(abs(a@transform - b@transform) < tol) &&
    all(abs(a@extent - b@extent) < tol) &&
    length(a@dims) == length(b@dims) &&
    all(a@dims == b@dims)
}
