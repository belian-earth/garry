# Test fixtures: small GeoTIFFs generated once per test run in tempdir()
# via gdalraster::create(). Asymmetric values (row*100 + col, 1-based)
# make any transpose/flip bug loud.

.fixture_env <- new.env(parent = emptyenv())

.fixture_values <- function(nx, ny) {
  outer(seq_len(ny), seq_len(nx), function(r, c2) r * 100 + c2)  # [y, x]
}

# f32, EPSG:32632, 10 m pixels, 60 wide x 40 tall.
fixture_gradient_f32 <- function() {
  if (!is.null(.fixture_env$grad)) return(.fixture_env$grad)
  f <- file.path(tempdir(), "garry-fixture-grad.tif")
  ds <- gdalraster::create("GTiff", f, 60, 40, 1, "Float32",
                           return_obj = TRUE)
  ds$setGeoTransform(c(500000, 10, 0, 4600000, 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  ds$write(1, 0, 0, 60, 40, as.numeric(t(.fixture_values(60, 40))))
  ds$close()
  .fixture_env$grad <- f
  f
}

# i16 with nodata -9999, tiled 16x16, EPSG:32632, 70 wide x 50 tall.
# Nodata cells: a 5x5 block at rows 10-14, cols 20-24 (1-based), plus
# cell [1, 1].
fixture_i16_nodata <- function() {
  if (!is.null(.fixture_env$i16)) return(.fixture_env$i16)
  f <- file.path(tempdir(), "garry-fixture-i16.tif")
  ds <- gdalraster::create(
    "GTiff", f, 70, 50, 1, "Int16", return_obj = TRUE,
    options = c("TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"))
  ds$setGeoTransform(c(400000, 20, 0, 4500000, 0, -20))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  m <- .fixture_values(70, 50)
  m[10:14, 20:24] <- -9999
  m[1, 1] <- -9999
  ds$write(1, 0, 0, 70, 50, as.numeric(t(m)))
  ds$setNoDataValue(1, -9999)
  ds$close()
  .fixture_env$i16 <- f
  f
}

# f64, EPSG:3857, 30 wide x 20 tall.
fixture_3857_f64 <- function() {
  if (!is.null(.fixture_env$m3857)) return(.fixture_env$m3857)
  f <- file.path(tempdir(), "garry-fixture-3857.tif")
  ds <- gdalraster::create("GTiff", f, 30, 20, 1, "Float64",
                           return_obj = TRUE)
  ds$setGeoTransform(c(-10000, 100, 0, 5000, 0, -100))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  ds$write(1, 0, 0, 30, 20, as.numeric(t(.fixture_values(30, 20))))
  ds$close()
  .fixture_env$m3857 <- f
  f
}

# f32 random noise (identifiable for kernel-recovery tests: convolution
# of a LINEAR surface is invariant to symmetric mass-1 kernels, so the
# gradient fixture must not be used for convergence tests).
fixture_random_f32 <- function() {
  if (!is.null(.fixture_env$rand)) return(.fixture_env$rand)
  f <- file.path(tempdir(), "garry-fixture-rand.tif")
  set.seed(99)
  ds <- gdalraster::create("GTiff", f, 80, 60, 1, "Float32",
                           return_obj = TRUE)
  ds$setGeoTransform(c(500000, 10, 0, 4600000, 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  ds$write(1, 0, 0, 80, 60, runif(80 * 60))
  ds$close()
  .fixture_env$rand <- f
  f
}

# 6-band f32 GTiff with DEFLATE (pixel-interleaved 1-row strips: the
# production embed_read layout), asymmetric per-band values. Returns
# list(path, nx, ny, nb, vals).
fixture_multiband <- function() {
  if (!is.null(.fixture_env$mb)) return(.fixture_env$mb)
  f <- file.path(tempdir(), "garry-fixture-mb.tif")
  nx <- 60L; ny <- 40L; nb <- 6L
  ds <- gdalraster::create("GTiff", f, nx, ny, nb, "Float32",
                           options = c("COMPRESS=DEFLATE",
                                       "INTERLEAVE=PIXEL"),
                           return_obj = TRUE)
  ds$setGeoTransform(c(500000, 10, 0, 4600000, 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  vals <- lapply(seq_len(nb), function(b)
    .fixture_values(nx, ny) * b / 10)
  for (b in seq_len(nb))
    ds$write(b, 0, 0, nx, ny, as.numeric(t(vals[[b]])))
  ds$close()
  .fixture_env$mb <- list(path = f, nx = nx, ny = ny, nb = nb, vals = vals)
  .fixture_env$mb
}
