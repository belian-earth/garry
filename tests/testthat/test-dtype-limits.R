# Values at the ends of a dtype's range, where a wrap or an f32 carrier shows.
# Each row reaches the wide accumulators on a 6 x 4 raster: sums of 24 cells
# already pass 2^31, and 2^24 + 1 and 1.1 are values no f32 holds.

# The ends of each band's range. Float ends are powers of two, which add up
# exactly in any order.
.dl_ends <- list(
  Byte = c(0, 255),
  Int8 = c(-128, 127),
  UInt16 = c(0, 65535),
  Int16 = c(-32768, 32767),
  UInt32 = c(0, 4294967295),
  Int32 = c(-2147483647, 2147483647), # -2^31 is R's NA_integer_
  Float32 = c(-2^100, 2^100),
  Float64 = c(-2^1000, 2^1000)
)
.dl_dtype <- c(Byte = "u8", Int8 = "i8", UInt16 = "u16", Int16 = "i16",
               UInt32 = "u32", Int32 = "i32", Float32 = "f32", Float64 = "f64")

.dl_m <- function(v, nx = 6L) matrix(rep_len(as.numeric(v), nx * 4L), 4L, nx, byrow = TRUE)
.dl_tile <- function(v, type, ...) fixture_tile(v, type, nx = 6L, ...)

test_that("a dtype's range ends add up, in one chunk or many", {
  for (type in names(.dl_ends)) {
    dt <- .dl_dtype[[type]]
    float <- startsWith(dt, "f")
    for (v in setdiff(.dl_ends[[type]], 0)) {
      x <- lazy_source(.dl_tile(v, type))
      m <- .dl_m(v)
      stk <- lazy_stack(list(x, x), along = "t")
      wide <- if (dt %in% c("i32", "u32")) "i64" else "i32"
      for (px in c(1e6, 4)) {
        info <- paste(type, v, px)
        expect_plan(reduce_over(x, "sum", c("x", "y")), sum(m), if (float) dt else "i64",
                    px = px, info = info)
        expect_plan(reduce_over(x, "mean", c("x", "y")), mean(m), if (float) dt else "f32",
                    px = px, info = info)
        expect_plan(reduce_over(stk, "sum", "t"), m * 2, if (float) dt else wide,
                    px = px, file = px == 4, info = info)
      }
    }
  }
})

test_that("a 16-bit sum past 2^31 in one chunk does not wrap", {
  # the size is the point: a chunk's sum has to leave i32
  for (row in list(list("Int16", 32767, 257L), list("UInt16", 65535, 182L))) {
    v <- row[[2L]]
    n <- row[[3L]]
    x <- lazy_source(fixture_tile(v, row[[1L]], nx = n, ny = n))
    expect_gt(v * n^2, 2^31)
    expect_plan(reduce_over(x, "sum", c("x", "y")), v * n^2, "i64", info = row[[1L]])
    expect_plan(reduce_over(x, "mean", c("x", "y")), v, "f32", info = row[[1L]])
  }
})

test_that("+ 1L stays exact up to a dtype's end", {
  for (type in names(.dl_ends)) {
    vals <- .dl_ends[[type]] - c(0, 1)
    x <- lazy_source(.dl_tile(vals, type))
    m <- .dl_m(vals)
    want <- if (type == "Float32") .as_f32(m + 1) else m + 1
    for (px in c(1e6, 4)) {
      expect_plan(x + 1L, want, .dl_dtype[[type]], px = px, file = px == 4, info = type)
    }
  }
})

test_that("a spatial integer sum declares a dtype that holds it", {
  x <- lazy_source(fixture_tile(1, "Int16"))
  expect_identical(reduce_over(x, "sum", "x")@grid@dtype, "i64")
  stk <- lazy_stack(list(x, x), along = "t")
  expect_identical(reduce_over(stk, "sum", c("x", "y"))@grid@dtype, "i64")
})

# Values no f32 holds, on each path a read can take. A sentinel, a scale, a
# mosaic or a window makes a float of an integer band, and that float must
# be one that holds the band.
.dl_reads <- list(
  Int32 = list(v = 2^24 + 1, dtype = "i32"),
  Float64 = list(v = 1.1, dtype = "f64")
)

test_that("a wide value survives every read path", {
  g <- function(nx, dt) {
    grid_spec("EPSG:3857", extent = c(0, 0, nx * 10, 40), dims = c(x = nx, y = 4L), dtype = dt)
  }
  for (type in names(.dl_reads)) {
    r <- .dl_reads[[type]]
    v <- r$v
    m <- .dl_m(v)
    f <- .dl_tile(v, type)
    x <- lazy_source(f)
    expect_plan(x, m, r$dtype, info = type)
    # a sentinel, or the file's own
    expect_plan(lazy_source(f, nodata = -1), m, "f64", info = type)
    expect_plan(lazy_source(.dl_tile(v, type, nodata = -1)), m, "f64", info = type)
    expect_plan(lazy_source(f, nodata = -1) + 0, m, "f64", info = type)
    # a scale
    expect_plan(lazy_source(f, scale = 2), m * 2, "f64", info = type)
    expect_plan(lazy_source(f, scale = 2, offset = 0.5), m * 2 + 0.5, "f64", info = type)
    # a warp, onto the band's grid and past its footprint
    expect_plan(align_to(x, g(6L, r$dtype)), m, r$dtype, info = type)
    past <- cbind(m, NaN, NaN)
    expect_plan(align_to(x, g(8L, r$dtype)), past, r$dtype, file = FALSE, info = type)
    # a raw cube
    vrt <- withr::local_tempfile(fileext = ".vrt")
    stage_raw_cube(f, vrt)
    expect_plan(lazy_source(vrt), m, "f64", info = type)
    # a window, where the stencil's float holds the band
    want <- .dl_m(v)
    want[1L, ] <- NaN
    want[, 1L] <- NaN
    expect_plan(focal_map(x, function(sh) sh[[1L]], 1L), want, "f64", info = type)
  }
})

test_that("16-bit sources stay f32 under a sentinel", {
  x <- lazy_source(.dl_tile(1, "Int16"), nodata = -1)
  expect_identical(x@grid@dtype, "f32")
})

test_that("window warps of a wide source keep its values", {
  v <- 1.1
  tile <- function(x0) .dl_tile(v, "Float64", gt = c(x0, 10, 0, 40, 0, -10))
  g <- grid_spec("EPSG:3857", extent = c(0, 0, 120, 40), dims = c(x = 12L, y = 4L), dtype = "f64")
  x <- lazy_source(c(tile(0), tile(60)), grid = g)
  expect_plan(x, .dl_m(v, 12L), "f64")
  expect_plan(x + 0, .dl_m(v, 12L), "f64")
  h <- garry:::gdal_warp_window(tile(0), 1L, g, 0L, 0L, 6L, 4L)
  expect_true(all(h == v))
})

test_that("warp-on-read routes take only what f32 holds", {
  f <- tempfile()
  saveRDS(list(entries = data.frame(slice = "a")), paste0(f, ".meta.rds"))
  node <- function(dtype) {
    SourceNode(
      id = 1L,
      parents = integer(0),
      grid = grid_spec("EPSG:32632", extent = c(0, 0, 10, 10),
                       dims = c(x = 1L, y = 1L), dtype = dtype),
      path = paste0("GTI:", f),
      band = 1L,
      nodata = numeric(0),
      block_dim = integer(0),
      open_options = character(0)
    )
  }
  expect_true(garry:::.gd_source_ok(node("f32")))
  expect_true(garry:::.gd_source_ok(node("u16")))
  expect_false(garry:::.gd_source_ok(node("f64")))
  expect_false(garry:::.gd_source_ok(node("i32")))
})

test_that("every band declares its own dtype", {
  a <- .dl_tile(7, "Byte")
  b <- .dl_tile(1.5, "Float32")
  vrt <- withr::local_tempfile(fileext = ".vrt")
  band <- function(i, type, f) {
    glue::glue(
      '<VRTRasterBand dataType="{type}" band="{i}"><SimpleSource>',
      '<SourceFilename>{f}</SourceFilename><SourceBand>1</SourceBand>',
      '</SimpleSource></VRTRasterBand>'
    )
  }
  writeLines(c(
    '<VRTDataset rasterXSize="6" rasterYSize="4">',
    glue::glue("<SRS>{gdalraster::srs_to_wkt('EPSG:3857')}</SRS>"),
    "<GeoTransform>0, 10, 0, 40, 0, -10</GeoTransform>",
    band(1L, "Byte", a),
    band(2L, "Float32", b),
    "</VRTDataset>"
  ), vrt)
  ds <- lazy_dataset(vrt)
  expect_identical(ds[[1L]]@grid@dtype, "u8")
  expect_identical(ds[[2L]]@grid@dtype, "f32")
  expect_plan(ds[[2L]] + 0, .dl_m(1.5), "f32")
})

test_that("a band type garry has no dtype for is named", {
  f <- fixture_tile(1, "CFloat32")
  err <- expect_error(gdal_grid_spec(f), "unsupported GDAL data type")
  expect_match(conditionMessage(err), basename(f), fixed = TRUE)
})
