# ---------------------------------------------------------------------------
# GridSpec: the spatial identity of a LazyRaster.
#
# CRS + affine transform + extent + dimensions + dtype. Every LazyRaster
# carries one. Binary ops require grid equality; mismatches are resolved
# via explicit `align()`, which injects a WarpNode.
# ---------------------------------------------------------------------------

#' Spatial grid specification.
#'
#' @export
GridSpec <- S7::new_class(
  "GridSpec",
  properties = list(
    crs       = S7::class_character,
    transform = S7::class_numeric,   # length 6 (GDAL geotransform)
    extent    = S7::class_numeric,   # xmin, ymin, xmax, ymax
    dim       = S7::class_integer,   # nx, ny [, nt, nb]
    dtype     = S7::class_character  # "f32", "f64", "i32", ... anvil-aligned
  ),
  validator = function(self) {
    if (length(self@crs) != 1L)
      return("`crs` must be length 1")
    if (length(self@transform) != 6L)
      return("`transform` must be length 6 (GDAL geotransform)")
    if (length(self@extent) != 4L)
      return("`extent` must be length 4 (xmin, ymin, xmax, ymax)")
    if (self@extent[1L] >= self@extent[3L] ||
        self@extent[2L] >= self@extent[4L])
      return("`extent` must satisfy xmin < xmax and ymin < ymax")
    if (length(self@dim) < 2L || any(self@dim <= 0L))
      return("`dim` must have at least two positive entries (nx, ny)")
    if (length(self@dtype) != 1L)
      return("`dtype` must be length 1")
    NULL
  }
)

#' Structural equality of two grids (geometry only, not dtype).
#'
#' @export
grid_equal <- function(a, b, tol = 1e-9) {
  identical(a@crs, b@crs) &&
    length(a@transform) == length(b@transform) &&
    all(abs(a@transform - b@transform) < tol) &&
    length(a@extent) == length(b@extent) &&
    all(abs(a@extent - b@extent) < tol) &&
    length(a@dim) == length(b@dim) &&
    all(a@dim == b@dim)
}
