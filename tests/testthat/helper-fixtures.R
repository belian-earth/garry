# Test fixtures: small GeoTIFFs generated once per test run in tempdir()
# via gdalraster::create(). Asymmetric values (row*100 + col, 1-based)
# make any transpose/flip bug loud.

.fixture_env <- new.env(parent = emptyenv())

# The package's R sources. R CMD check has no R/ beside the tests and covr has one holding the
# installed code, so a test that scans them skips on the files themselves, not on the folder.
.r_sources <- function() {
  files <- list.files(testthat::test_path("..", "..", "R"), pattern = "\\.R$", full.names = TRUE)
  testthat::skip_if(length(files) == 0L, "package sources not available")
  files
}

.fixture_values <- function(nx, ny) {
  outer(seq_len(ny), seq_len(nx), function(r, c2) r * 100 + c2)  # [y, x]
}

# A small one-band tile, `vals` recycled over its cells in row order.
fixture_tile <- function(vals = 1, type = "Float32", nodata = NULL,
                         gt = c(0, 10, 0, 40, 0, -10), nx = 4L, ny = 4L,
                         crs = "EPSG:3857", scale = NULL) {
  f <- tempfile(fileext = ".tif")
  ds <- gdalraster::create("GTiff", f, nx, ny, 1L, type, return_obj = TRUE)
  ds$setGeoTransform(gt)
  ds$setProjection(gdalraster::srs_to_wkt(crs))
  ds$write(1L, 0L, 0L, nx, ny, as.numeric(rep_len(vals, nx * ny)))
  if (!is.null(nodata)) ds$setNoDataValue(1L, nodata)
  if (!is.null(scale)) ds$setScale(1L, scale)
  ds$close()
  f
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
  testthat::skip_if_not_installed("jsonlite")
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

# A Zarr store written by GDAL (gdalmdimtranslate of a multidimensional
# VRT): (time, band, y, x) Int8 arrays named `emb`, one per group as
# OlmoEarth lays its UTM zones out, 2 years x 3 bands of 20 x 30 px at 10 m,
# fill value -128 at the top-left pixel of every plane, georeferenced by x
# and y coordinate arrays and a CRS attribute:
#   /utm32/emb      EPSG:32632, where fixture_zarr_nd() lies
#   /utm33/emb      EPSG:32633, against /utm32/emb's east edge
#   /eqn/emb        EPSG:32632, just north of the equator
#   /eqs/emb        EPSG:32732, just south of it
#   /nest/far/emb   EPSG:32632, far from the others, in a nested group
#   /ova/emb        EPSG:32631, elsewhere
#   /ovb/emb        EPSG:32631, 100 m east of /ova/emb, overlapping it
#   /other/lut      a 3 x 2 Float32 table, not georeferenced
# `format` is "ZARR_V3" or "ZARR_V2"; `consolidated`, whether GDAL writes
# consolidated metadata. Returns the store, each array's name as GDAL lists
# it (`paths`, by group) and its values as an R array [t, b, y, x] (`vals`).
fixture_zarr_store <- function(format = "ZARR_V3", consolidated = TRUE) {
  key <- paste("zarr-store", format, consolidated)
  if (!is.null(.fixture_env[[key]])) {
    return(.fixture_env[[key]])
  }
  nt <- 2L
  nb <- 3L
  ny <- 20L
  nx <- 30L
  res <- 10
  xy33 <- gdalraster::transform_xy(
    cbind(500300, 4600000),
    "EPSG:32632",
    "EPSG:32633"
  )
  at <- list(
    utm32 = list(epsg = 32632L, x0 = 500000, y1 = 4600000, shift = 0L),
    utm33 = list(
      epsg = 32633L,
      x0 = round(xy33[1, 1], -1),
      y1 = round(xy33[1, 2], -1),
      shift = 7L
    ),
    eqn = list(epsg = 32632L, x0 = 500000, y1 = 200, shift = 3L),
    eqs = list(epsg = 32732L, x0 = 500000, y1 = 10000000, shift = 5L),
    `nest/far` = list(epsg = 32632L, x0 = 200000, y1 = 5000000, shift = 9L),
    ova = list(epsg = 32631L, x0 = 400000, y1 = 3000000, shift = 11L),
    ovb = list(epsg = 32631L, x0 = 400100, y1 = 3000000, shift = 13L)
  )
  num <- function(x) format(x, scientific = FALSE, trim = TRUE)
  vals <- list()
  group <- function(g) {
    a <- at[[g]]
    v <- array(0L, c(nt, nb, ny, nx))
    for (t in seq_len(nt)) {
      for (b in seq_len(nb)) {
        v[t, b, , ] <- outer(seq_len(ny), seq_len(nx), function(y, x) {
          (t * 40L + b * 10L + y + x + a$shift) %% 250L - 125L
        })
      }
    }
    v[,, 1, 1] <- -128L
    vals[[g]] <<- v
    inner <- paste0(
      '<Dimension name="time" size="',
      nt,
      '" indexingVariable="time"/>',
      '<Dimension name="band" size="',
      nb,
      '"/>',
      '<Dimension name="y" size="',
      ny,
      '" type="HORIZONTAL_Y" indexingVariable="y"/>',
      '<Dimension name="x" size="',
      nx,
      '" type="HORIZONTAL_X" indexingVariable="x"/>',
      '<Array name="time"><DataType>Int32</DataType><DimensionRef ref="time"/>',
      '<NoDataValue>0</NoDataValue><RegularlySpacedValues start="2021" increment="1"/></Array>',
      '<Array name="y"><DataType>Float64</DataType><DimensionRef ref="y"/><NoDataValue>NaN</NoDataValue>',
      '<RegularlySpacedValues start="',
      num(a$y1 - res / 2),
      '" increment="',
      -res,
      '"/></Array>',
      '<Array name="x"><DataType>Float64</DataType><DimensionRef ref="x"/><NoDataValue>NaN</NoDataValue>',
      '<RegularlySpacedValues start="',
      num(a$x0 + res / 2),
      '" increment="',
      res,
      '"/></Array>',
      '<Array name="emb"><DataType>Int8</DataType>',
      '<DimensionRef ref="time"/><DimensionRef ref="band"/><DimensionRef ref="y"/><DimensionRef ref="x"/>',
      '<SRS dataAxisToSRSAxisMapping="2,1">EPSG:',
      a$epsg,
      '</SRS><NoDataValue>-128</NoDataValue>',
      # C order: the last dimension varies fastest
      '<InlineValues>',
      paste(as.vector(aperm(v, 4:1)), collapse = " "),
      '</InlineValues></Array>'
    )
    parts <- strsplit(g, "/", fixed = TRUE)[[1L]]
    paste0(
      paste0('<Group name="', parts, '">', collapse = ""),
      inner,
      strrep("</Group>", length(parts))
    )
  }
  vrt <- paste0(
    '<VRTDataset><Group name="/">',
    paste(vapply(names(at), group, ""), collapse = ""),
    '<Group name="other"><Dimension name="r" size="3"/><Dimension name="c" size="2"/>',
    '<Array name="lut"><DataType>Float32</DataType><DimensionRef ref="r"/><DimensionRef ref="c"/>',
    '<NoDataValue>-1</NoDataValue><InlineValues>1 2 3 4 5 6</InlineValues></Array></Group>',
    "</Group></VRTDataset>"
  )
  dir <- file.path(tempdir(), "garry-fixture-store")
  dir.create(dir, showWarnings = FALSE)
  src <- file.path(dir, sprintf("%s-%s.vrt", format, consolidated))
  writeLines(vrt, src)
  store <- file.path(dir, sprintf("%s-%s.zarr", format, consolidated))
  unlink(store, recursive = TRUE)
  gdalraster::mdim_translate(
    src,
    store,
    output_format = "Zarr",
    creation_options = c(
      paste0("FORMAT=", format),
      paste0("CREATE_CONSOLIDATED_METADATA=", if (consolidated) "YES" else "NO")
    ),
    quiet = TRUE
  )
  .fixture_env[[key]] <- list(
    store = store,
    paths = vapply(
      names(at),
      function(g) sprintf('ZARR:"%s":/%s/emb', store, g),
      ""
    ),
    vals = vals
  )
  .fixture_env[[key]]
}

# A Zarr store GDAL writes with each of `arrays` at its root: a 20 x 30
# Int8 array in EPSG:32632 at 10 m from (500000, 4600000), the i-th one's
# values i * 10 plus the column modulo 7 and the row modulo 3, with or
# without consolidated metadata. Returns the store.
fixture_zarr_root <- function(
  arrays = "a",
  format = "ZARR_V3",
  consolidated = TRUE
) {
  key <- paste(c("zarr-root", arrays, format, consolidated), collapse = " ")
  if (!is.null(.fixture_env[[key]])) {
    return(.fixture_env[[key]])
  }
  ny <- 20L
  nx <- 30L
  arr <- vapply(
    seq_along(arrays),
    function(i) {
      v <- outer(seq_len(ny), seq_len(nx), function(y, x) {
        i * 10L + x %% 7L + y %% 3L
      })
      paste0(
        '<Array name="',
        arrays[[i]],
        '"><DataType>Int8</DataType>',
        '<DimensionRef ref="y"/><DimensionRef ref="x"/>',
        '<SRS dataAxisToSRSAxisMapping="2,1">EPSG:32632</SRS><NoDataValue>-128</NoDataValue>',
        # C order: the last dimension varies fastest
        "<InlineValues>",
        paste(as.vector(t(v)), collapse = " "),
        "</InlineValues></Array>"
      )
    },
    ""
  )
  vrt <- paste0(
    '<VRTDataset><Group name="/">',
    '<Dimension name="y" size="',
    ny,
    '" type="HORIZONTAL_Y" indexingVariable="y"/>',
    '<Dimension name="x" size="',
    nx,
    '" type="HORIZONTAL_X" indexingVariable="x"/>',
    '<Array name="y"><DataType>Float64</DataType><DimensionRef ref="y"/><NoDataValue>NaN</NoDataValue>',
    '<RegularlySpacedValues start="4599995" increment="-10"/></Array>',
    '<Array name="x"><DataType>Float64</DataType><DimensionRef ref="x"/><NoDataValue>NaN</NoDataValue>',
    '<RegularlySpacedValues start="500005" increment="10"/></Array>',
    paste(arr, collapse = ""),
    "</Group></VRTDataset>"
  )
  src <- tempfile("garry-fixture-root-", fileext = ".vrt")
  writeLines(vrt, src)
  store <- sub("vrt$", "zarr", src)
  gdalraster::mdim_translate(
    src,
    store,
    output_format = "Zarr",
    creation_options = c(
      paste0("FORMAT=", format),
      paste0("CREATE_CONSOLIDATED_METADATA=", if (consolidated) "YES" else "NO")
    ),
    quiet = TRUE
  )
  .fixture_env[[key]] <- store
  store
}

# A Zarr store written by hand as zarr-python lays one out: GDAL's own
# georeferencing is absent, and each array is placed only by the
# zarr-conventions attributes proj:code, spatial:transform and
# spatial:shape. One Int16 array `v` of 20 x 30 px at 10 m, uncompressed,
# sits in a group per element of `at` (name = list(crs, x0, y1), plus
# `attrs` to add or, as NULL, drop attributes); the i-th holds i * 100 plus
# its row and column, and its fill value -1 at the top-left pixel. The
# attributes sit on the group, on the array (`on = "array"`), or only the
# first element's on the store's root (`on = "root"`). The store is
# consolidated at its root; a v3 store's groups too when `per_group`, as
# OlmoEarth's are. Returns the store.
fixture_zarr_declared <- function(
  at,
  on = "group",
  per_group = TRUE,
  format = 3L
) {
  root <- tempfile("garry-declared-", fileext = ".zarr")
  js <- function(x, ...) {
    path <- file.path(...)
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    writeLines(yyjsonr::write_json_str(x, auto_unbox = TRUE), path)
  }
  obj <- function(x = NULL) {
    if (length(x)) x else structure(list(), names = character(0))
  }
  conv <- list(
    list(uuid = "f17cb550-5864-4468-aeb7-f3180cfb622f", name = "proj"),
    list(uuid = "689b58e2-cf7b-45e0-9fff-9cfc0883d6b4", name = "spatial")
  )
  meta <- list()
  top <- NULL
  for (i in seq_along(at)) {
    g <- names(at)[[i]]
    a <- at[[g]]
    decl <- utils::modifyList(
      list(
        zarr_conventions = conv,
        `proj:code` = a$crs,
        `spatial:dimensions` = c("y", "x"),
        `spatial:transform` = c(10, 0, a$x0, 0, -10, a$y1),
        `spatial:shape` = c(20L, 30L)
      ),
      a$attrs %||% list()
    )
    top <- if (i == 1L && on == "root") decl else top
    ga <- obj(if (on == "group") decl)
    aa <- obj(if (on == "array") decl)
    v <- outer(1:20, 1:30, function(y, x) i * 100L + y + x)
    v[1L, 1L] <- -1L
    if (format == 3L) {
      arr <- list(
        zarr_format = 3L,
        node_type = "array",
        shape = c(20L, 30L),
        data_type = "int16",
        chunk_grid = list(
          name = "regular",
          configuration = list(chunk_shape = c(20L, 30L))
        ),
        chunk_key_encoding = list(
          name = "default",
          configuration = list(separator = "/")
        ),
        fill_value = -1L,
        codecs = list(list(
          name = "bytes",
          configuration = list(endian = "little")
        )),
        attributes = aa,
        dimension_names = c("y", "x")
      )
      grp <- list(zarr_format = 3L, node_type = "group", attributes = ga)
      meta[[g]] <- grp
      meta[[paste0(g, "/v")]] <- arr
      if (per_group) {
        grp$consolidated_metadata <- list(
          kind = "inline",
          must_understand = FALSE,
          metadata = list(v = arr)
        )
      }
      js(grp, root, g, "zarr.json")
      js(arr, root, g, "v", "zarr.json")
      chunk <- file.path(root, g, "v", "c", "0", "0")
    } else {
      arr <- list(
        zarr_format = 2L,
        shape = c(20L, 30L),
        chunks = c(20L, 30L),
        dtype = "<i2",
        compressor = NULL,
        fill_value = -1L,
        order = "C",
        filters = NULL
      )
      aa[["_ARRAY_DIMENSIONS"]] <- c("y", "x")
      meta[[paste0(g, "/.zgroup")]] <- list(zarr_format = 2L)
      meta[[paste0(g, "/.zattrs")]] <- ga
      meta[[paste0(g, "/v/.zarray")]] <- arr
      meta[[paste0(g, "/v/.zattrs")]] <- aa
      js(list(zarr_format = 2L), root, g, ".zgroup")
      js(ga, root, g, ".zattrs")
      js(arr, root, g, "v", ".zarray")
      js(aa, root, g, "v", ".zattrs")
      chunk <- file.path(root, g, "v", "0.0")
    }
    dir.create(dirname(chunk), recursive = TRUE, showWarnings = FALSE)
    con <- file(chunk, "wb")
    writeBin(as.integer(t(v)), con, size = 2L, endian = "little")
    close(con)
  }
  if (format == 3L) {
    js(
      list(
        zarr_format = 3L,
        node_type = "group",
        attributes = obj(top),
        consolidated_metadata = list(
          kind = "inline",
          must_understand = FALSE,
          metadata = meta
        )
      ),
      root,
      "zarr.json"
    )
  } else {
    js(list(zarr_format = 2L), root, ".zgroup")
    js(obj(top), root, ".zattrs")
    meta[[".zgroup"]] <- list(zarr_format = 2L)
    meta[[".zattrs"]] <- obj(top)
    js(list(metadata = meta, zarr_consolidated_format = 1L), root, ".zmetadata")
  }
  root
}
