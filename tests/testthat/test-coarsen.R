# coarsen(): block means of a read, the read assembled from its sources
# by nearest neighbour onto the finer grid. Pinned to R references and
# to the two-stage path it replaces (10 m codes written, then decoded
# and averaged).

# Int8 codes in UTM 36S, nodata -128: two south-up tiles of 9 x 6 px at
# 10 m, the second overlapping the first by three columns, with
# scattered nodata and a nodata block.
.ctiles <- function() {
  dir <- file.path(tempdir(), "garry-coarsen-tiles")
  dir.create(dir, showWarnings = FALSE)
  mk <- function(name, x0, seed) {
    f <- file.path(dir, name)
    if (!file.exists(f)) {
      set.seed(seed)
      ds <- gdalraster::create(
        "GTiff",
        f,
        9L,
        6L,
        2L,
        "Int8",
        return_obj = TRUE
      )
      ds$setProjection(gdalraster::srs_to_wkt("EPSG:32736"))
      ds$setGeoTransform(c(x0, 10, 0, 8600000, 0, 10))
      for (b in 1:2) {
        v <- sample(-127:127, 54L, replace = TRUE)
        v[sample(54L, 6L)] <- -128L
        v[1:3] <- -128L
        ds$setNoDataValue(b, -128)
        ds$write(b, 0L, 0L, 9L, 6L, v)
      }
      ds$close()
    }
    f
  }
  c(mk("a.tif", 500000, 1L), mk("b.tif", 500060, 2L))
}

# The tiles' 10 m grid and its 3x coarser one (15 x 6 px; 5 x 2 px).
.c10 <- function() {
  grid_spec("EPSG:32736", c(500000, 8600000, 500150, 8600060), res = 10)
}
.c30 <- function() {
  grid_spec("EPSG:32736", c(500000, 8600000, 500150, 8600060), res = 30)
}

.f32c <- function(v) {
  readBin(
    writeBin(as.numeric(v), raw(), size = 4L),
    "numeric",
    length(v),
    size = 4L
  )
}

# R reference: k x k block means (row by row, in order) of a [y, x]
# matrix, NaN where no value is valid.
.block_mean <- function(m, k) {
  out <- matrix(NaN, nrow(m) %/% k, ncol(m) %/% k)
  for (r in seq_len(nrow(out))) {
    for (q in seq_len(ncol(out))) {
      blk <- t(m[(k * r - k + 1):(k * r), (k * q - k + 1):(k * q)])
      ok <- !is.nan(blk)
      if (any(ok)) out[r, q] <- .f32c(Reduce(`+`, blk[ok]) / sum(ok))
    }
  }
  out
}

.decode_m <- function(m) {
  out <- .f32c(dequantize_aef(m))
  out[is.nan(m)] <- NaN
  dim(out) <- dim(m)
  out
}

test_that("coarsen averages a plain read's blocks", {
  f <- fixture_gradient_f32()
  x <- lazy_source(f)
  got <- collect(coarsen(x, 4L), distributed = FALSE)
  full <- collect(x, distributed = FALSE)
  expect_equal(
    unname(got),
    .block_mean(unname(full), 4L),
    tolerance = 0,
    ignore_attr = TRUE
  )
  expect_identical(coarsen(x, 1L), x)
})

test_that("a decoded mosaic coarsens as its 10 m codes decode and average", {
  tiles <- .ctiles()
  codes <- lazy_dataset(
    tiles,
    .c10(),
    resampling = "near",
    decode = dequantize_aef
  )
  cube <- coarsen(codes, 3L)
  expect_named(cube@bands, names(codes@bands))
  got <- collect(stack_bands(cube), distributed = FALSE)
  expect_identical(dim(got), c(2L, 5L, 2L))
  # the 10 m codes the two-stage path writes (#41's mosaic, later tiles
  # winning where they hold data), decoded and averaged in R
  raw10 <- collect(
    stack_bands(lazy_dataset(tiles, .c10(), resampling = "near")),
    distributed = FALSE
  )
  for (b in 1:2) {
    want <- .block_mean(.decode_m(unname(raw10[,, b])), 3L)
    expect_identical(unname(got[,, b]), want)
  }
  # the decoded 10 m read (k = 1) is the decoded codes
  dec10 <- collect(stack_bands(codes), distributed = FALSE)
  expect_identical(unname(dec10[,, 1L]), .decode_m(unname(raw10[,, 1L])))
  # and the codes-file path's cube is the same
  f <- withr::local_tempfile(fileext = ".tif")
  write_tif(
    lazy_dataset(tiles, .c10(), resampling = "near"),
    f,
    dtype = "i8",
    nodata = -128L
  )
  two <- collect(
    stack_bands(lazy_dataset(
      f,
      .c30(),
      resampling = "average",
      decode = dequantize_aef
    )),
    distributed = FALSE
  )
  expect_equal(got, two, tolerance = 0, ignore_attr = TRUE)
})

test_that("a tile in another projection is warped alone, as the 10 m read warps it", {
  tiles <- .ctiles()
  other <- file.path(tempdir(), "garry-coarsen-tiles", "b-35.tif")
  if (!file.exists(other)) {
    gdalraster::warp(
      tiles[[2L]],
      other,
      t_srs = "EPSG:32735",
      cl_arg = c("-r", "near"),
      quiet = TRUE
    )
  }
  srcs <- c(tiles[[1L]], other)
  codes <- lazy_dataset(
    srcs,
    .c10(),
    resampling = "near",
    decode = dequantize_aef
  )
  p <- plan_lazy(stack_bands(coarsen(codes, 3L)))
  ws <- Filter(function(s) s@kind == "warp", p@stages)[[1L]]
  parts <- .stage_read_args(p@graph, ws)$decim$parts
  expect_false(isTRUE(parts[[1L]]$warp))
  expect_true(parts[[2L]]$warp)
  # picks independent of the window: the coarsened read equals the
  # two-stage path (10 m codes written, then decoded and averaged)
  withr::local_options(garry.warp_exact = TRUE)
  got <- collect(stack_bands(coarsen(codes, 3L)), distributed = FALSE)
  f <- withr::local_tempfile(fileext = ".tif")
  write_tif(
    lazy_dataset(srcs, .c10(), resampling = "near"),
    f,
    dtype = "i8",
    nodata = -128L
  )
  two <- collect(
    stack_bands(lazy_dataset(
      f,
      .c30(),
      resampling = "average",
      decode = dequantize_aef
    )),
    distributed = FALSE
  )
  expect_equal(got, two, tolerance = 0, ignore_attr = TRUE)
  expect_true(any(!is.nan(got[, 5L, ])))
})

test_that("an N-D dataset coarsens slice by slice", {
  skip_if_not_installed("jsonlite")
  fx <- fixture_zarr_nd()
  g <- grid_spec("EPSG:32632", c(500000, 4599800, 500300, 4600000), res = 10)
  ds <- time_sel(lazy_dataset(fx$path, g), "2023")
  got <- collect(stack_bands(coarsen(ds, 2L)), distributed = FALSE)
  full <- collect(stack_bands(ds), distributed = FALSE)
  for (b in 1:4) {
    expect_identical(unname(got[,, b]), .block_mean(unname(full[,, b]), 2L))
  }
})

test_that("a pooled coarsened write matches the single-process one", {
  skip_on_cran()
  cube <- function() {
    stack_bands(coarsen(
      lazy_dataset(
        .ctiles(),
        .c10(),
        resampling = "near",
        decode = dequantize_aef
      ),
      3L
    ))
  }
  f1 <- withr::local_tempfile(fileext = ".tif")
  f2 <- withr::local_tempfile(fileext = ".tif")
  write_tif(cube(), f2, distributed = FALSE)
  local_pools(2, 1)
  write_tif(cube(), f1, distributed = TRUE)
  rd <- function(f) {
    d <- methods::new(gdalraster::GDALRaster, f)
    on.exit(d$close())
    lapply(1:2, function(b) d$read(b, 0L, 0L, 5L, 2L, 5L, 2L))
  }
  expect_identical(rd(f1), rd(f2))
})

test_that("coarsen keeps apart from an ordinary warp of the same source", {
  f <- .ctiles()[[1L]]
  x <- lazy_source(f, band = 1L)
  a <- coarsen(align_to(x, .c10()), 3L)
  b <- align_to(x, .c30())
  both <- collect(a - b, distributed = FALSE)
  alone <- collect(a, distributed = FALSE) - collect(b, distributed = FALSE)
  expect_equal(both, alone, tolerance = 1e-6, ignore_attr = TRUE)
  expect_true(any(abs(alone) > 0, na.rm = TRUE))
})

test_that("decoded codes coarsen from full resolution, never an overview", {
  f <- file.path(tempdir(), "garry-coarsen-ovr.tif")
  if (!file.exists(f)) {
    set.seed(5)
    ds <- gdalraster::create(
      "GTiff",
      f,
      96L,
      96L,
      1L,
      "Byte",
      return_obj = TRUE
    )
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:32736"))
    ds$setGeoTransform(c(500000, 10, 0, 8600000, 0, -10))
    ds$write(1L, 0L, 0L, 96L, 96L, sample(c(0L, 200L), 9216L, replace = TRUE))
    ds$close()
    ds <- methods::new(gdalraster::GDALRaster, f, read_only = FALSE)
    ds$buildOverviews("AVERAGE", c(2L, 4L), 1L)
    ds$close()
  }
  # a 20 m finer grid over 10 m codes: warped by nearest, then 2 x 2 means
  g20 <- grid_spec("EPSG:32736", c(500000, 8599040, 500960, 8600000), res = 20)
  cube <- coarsen(
    lazy_dataset(f, g20, resampling = "near", decode = function(x) x^2),
    2L
  )
  got <- collect(stack_bands(cube), distributed = FALSE)
  expect_true(all(got %in% c(0, 10000, 20000, 30000, 40000)))
})

test_that("coarsen refuses what it cannot average", {
  x <- lazy_source(fixture_gradient_f32())
  expect_error(coarsen(x + 1, 2L), "averages a read")
  expect_error(coarsen(x, 0), "whole number")
  expect_error(coarsen(x, 2.5), "whole number")
  expect_error(coarsen(x, 7L), "does not divide")
  expect_error(coarsen(x, 2L, fun = "max"), "mean")
  bil <- lazy_dataset(.ctiles()[[1L]], .c10(), resampling = "bilinear")
  expect_error(coarsen(bil, 3L), "nearest-neighbour")
  expect_error(
    coarsen(lazy_source(.ctiles()[[1L]], resampling = "bilinear"), 3L),
    "nearest-neighbour"
  )
  oo <- lazy_source(
    .ctiles()[[1L]],
    open_options = "OVERVIEW_LEVEL=NONE"
  )
  expect_error(coarsen(oo, 3L), "open options")
  m <- lazy_dataset(.ctiles()[[1L]], mask_asset = "b2")
  expect_error(coarsen(m, 3L), "mask band")
})

test_that("block means of f32 planes, decoded or not, in C", {
  f32 <- function(x) writeBin(as.numeric(x), raw(), size = 4L)
  # one band, a 4 x 2 slab of 2 x 2 blocks: rows (1, 2, NaN, 4) and (3, NaN, NaN, NaN)
  src <- f32(c(1, 2, NaN, 4, 3, NaN, NaN, NaN))
  out <- .Call("garry_alloc_double", 2, PACKAGE = "garry")
  .Call(
    "garry_coarsen_into",
    out,
    0,
    src,
    c(1, 2, 2, 1, 2, 0),
    numeric(0),
    PACKAGE = "garry"
  )
  expect_identical(out, c(2, 4))
  # decoded: codes 0 and 1 through a table from code 0, code 2 nodata
  tab <- c(0.5, 1, NaN)
  src <- f32(c(0, 1, 2, 2, 1, 1, NaN, 2))
  .Call(
    "garry_coarsen_into",
    out,
    0,
    src,
    c(1, 2, 2, 1, 2, 0),
    tab,
    PACKAGE = "garry"
  )
  expect_identical(out, c((0.5 + 1 + 1 + 1) / 4, NaN))
  expect_error(
    .Call(
      "garry_coarsen_into",
      out,
      1,
      src,
      c(1, 2, 2, 1, 2, 0),
      tab,
      PACKAGE = "garry"
    ),
    "does not coarsen"
  )
})
