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

# A (time, band, y, x) Int8 Zarr v3 array, the OlmoEarth layout in
# miniature: 3 years x 4 bands of 20 x 30 px at 10 m in EPSG:32632, chunks
# spanning 2 bands, fill value -128 (nodata) at the top-left pixel of
# every plane. Written by hand (uncompressed `bytes` codec) so no Zarr
# writer is needed. Georeferenced twice over: the spatial/proj Zarr
# conventions (GDAL >= 3.13) and x/y coordinate arrays plus a _CRS
# attribute (older GDAL). Returns the store, its ZARR: connection string
# and the values as an R array [t, b, y, x].
#
# `epsg`, `x0`, `y1` and `shift` (added to every value) place a second
# store elsewhere, e.g. in the next UTM zone for cross-zone reads;
# `year0` is the first year of the time coordinate.
fixture_zarr_nd <- function(epsg = 32632L, x0 = 500000, y1 = 4600000,
                            shift = 0L, year0 = 2021L) {
  key <- paste("zarr", epsg, x0, y1, shift, year0)
  if (!is.null(.fixture_env[[key]])) return(.fixture_env[[key]])
  store <- file.path(
    tempdir(),
    sprintf("garry-fixture-nd-%d-%d-%d-%d.zarr", epsg, round(x0), shift, year0)
  )
  nt <- 3L; nb <- 4L; ny <- 20L; nx <- 30L; chunk <- c(1L, 2L, 10L, 15L)
  res <- 10
  js <- function(x, path) {
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    writeLines(jsonlite::toJSON(x, auto_unbox = TRUE, digits = NA), path)
  }
  raw_codec <- list(list(name = "bytes", configuration = list(endian = "little")))
  key_enc <- list(name = "default", configuration = list(separator = "/"))
  js(list(
    zarr_format = 3L, node_type = "group",
    attributes = list(
      zarr_conventions = list(
        list(name = "spatial", uuid = "689b58e2-cf7b-45e0-9fff-9cfc0883d6b4"),
        list(name = "proj", uuid = "f17cb550-5864-4468-aeb7-f3180cfb622f")
      ),
      `proj:code` = paste0("EPSG:", epsg),
      `spatial:dimensions` = c("y", "x"),
      `spatial:transform` = c(res, 0, x0, 0, -res, y1),
      `spatial:shape` = c(ny, nx),
      `spatial:registration` = "pixel"
    )
  ), file.path(store, "zarr.json"))
  coord <- function(name, vals, dtype, size) {
    js(list(
      zarr_format = 3L, node_type = "array", shape = I(length(vals)),
      data_type = dtype,
      chunk_grid = list(name = "regular",
                        configuration = list(chunk_shape = I(length(vals)))),
      chunk_key_encoding = key_enc, fill_value = 0, codecs = raw_codec,
      dimension_names = I(name), attributes = structure(list(), names = character(0))
    ), file.path(store, name, "zarr.json"))
    f <- file.path(store, name, "c", "0")
    dir.create(dirname(f), recursive = TRUE, showWarnings = FALSE)
    writeBin(vals, f, size = size, endian = "little")
  }
  coord("time", year0 + seq_len(nt) - 1L, "int32", 4L)
  coord("y", y1 - res * (seq_len(ny) - 0.5), "float64", 8L)
  coord("x", x0 + res * (seq_len(nx) - 0.5), "float64", 8L)
  js(list(
    zarr_format = 3L, node_type = "array", shape = c(nt, nb, ny, nx),
    data_type = "int8",
    chunk_grid = list(name = "regular", configuration = list(chunk_shape = chunk)),
    chunk_key_encoding = key_enc, fill_value = -128L,
    codecs = list(list(name = "bytes")),
    dimension_names = c("time", "band", "y", "x"),
    attributes = list(`_CRS` = list(url = paste0("http://www.opengis.net/def/crs/EPSG/0/", epsg)))
  ), file.path(store, "data", "zarr.json"))
  vals <- array(0L, c(nt, nb, ny, nx))
  for (t in seq_len(nt)) for (b in seq_len(nb)) {
    vals[t, b, , ] <- outer(seq_len(ny), seq_len(nx),
                            function(y, x) (t * 40L + b * 10L + y + x + shift) %% 250L - 125L)
  }
  vals[, , 1, 1] <- -128L
  nc <- c(nt, nb, ny, nx) %/% chunk
  for (ct in seq_len(nc[1]) - 1L) for (cb in seq_len(nc[2]) - 1L)
    for (cy in seq_len(nc[3]) - 1L) for (cx in seq_len(nc[4]) - 1L) {
      blk <- vals[ct * chunk[1] + seq_len(chunk[1]), cb * chunk[2] + seq_len(chunk[2]),
                  cy * chunk[3] + seq_len(chunk[3]), cx * chunk[4] + seq_len(chunk[4]),
                  drop = FALSE]
      f <- file.path(store, "data", "c", ct, cb, cy, cx)
      dir.create(dirname(f), recursive = TRUE, showWarnings = FALSE)
      # C order: the last dim varies fastest
      writeBin(as.vector(aperm(blk, 4:1)), f, size = 1L)
    }
  .fixture_env[[key]] <- list(
    store = store,
    path = sprintf('ZARR:"%s":/data', store),
    vals = vals
  )
  .fixture_env[[key]]
}
