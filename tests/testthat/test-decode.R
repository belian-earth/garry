# lazy_dataset(decode =): 8-bit codes decoded before resampling. Every
# read goes through a lookup-table VRT; an aligned "near" or "average"
# read decodes the codes itself, which these tests pin to the VRT's
# GDAL reads and to an R reference.

# Int8 codes, 12 x 9 px at 10 m (UTM 36S), 3 bands, nodata -128 at
# scattered cells and over the whole top-left 3 x 3 block.
.coded <- function(interleave = "BAND", south_up = FALSE) {
  f <- file.path(
    tempdir(),
    paste0("garry-coded-", interleave, if (south_up) "-s", ".tif")
  )
  if (!file.exists(f)) {
    set.seed(7)
    ds <- gdalraster::create(
      "GTiff",
      f,
      12L,
      9L,
      3L,
      "Int8",
      options = paste0("INTERLEAVE=", interleave),
      return_obj = TRUE
    )
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:32736"))
    ds$setGeoTransform(
      if (south_up) {
        c(500000, 10, 0, 8599910, 0, 10)
      } else {
        c(500000, 10, 0, 8600000, 0, -10)
      }
    )
    for (b in 1:3) {
      v <- matrix(sample(-127:127, 108L, replace = TRUE), 9L, 12L) # [y, x]
      v[sample(108L, 12L)] <- -128L
      v[1:3, 1:3] <- -128L
      ds$setNoDataValue(b, -128)
      # rows as stored: a south-up file holds its southern row first
      ds$write(b, 0L, 0L, 12L, 9L, as.vector(t(if (south_up) v[9:1, ] else v)))
    }
    ds$close()
  }
  f
}

# The codes as a [y, x] matrix, north first.
.codes_of <- function(f, b) {
  m <- gdal_read_window(f, b, 0L, 0L, 12L, 9L)
  m[is.nan(m)] <- -128
  m
}

.f32 <- function(v) {
  readBin(
    writeBin(as.numeric(v), raw(), size = 4L),
    "numeric",
    length(v),
    size = 4L
  )
}

# Decoded values (f32, NaN at nodata) of codes `m`.
.decoded <- function(m) {
  out <- .f32(dequantize_aef(m))
  out[m == -128] <- NaN
  dim(out) <- dim(m)
  out
}

# k x k block means (row by row, in order) of a decoded [y, x] matrix,
# NaN where no value is valid, rounded to f32.
.block_mean_dec <- function(m, k) {
  out <- matrix(NaN, nrow(m) %/% k, ncol(m) %/% k)
  for (r in seq_len(nrow(out))) {
    for (q in seq_len(ncol(out))) {
      blk <- t(m[(k * r - k + 1):(k * r), (k * q - k + 1):(k * q)])
      ok <- !is.nan(blk)
      if (any(ok)) out[r, q] <- .f32(Reduce(`+`, blk[ok]) / sum(ok))
    }
  }
  out
}

.g10 <- function() {
  grid_spec("EPSG:32736", c(500000, 8599910, 500120, 8600000), res = 10)
}
# the source's pixels less a one-pixel margin: a warp, not the source grid
.g10_in <- function() {
  grid_spec("EPSG:32736", c(500010, 8599920, 500110, 8599990), res = 10)
}
.g30 <- function() {
  grid_spec("EPSG:32736", c(500000, 8599910, 500120, 8600000), res = 30)
}

# The lookup-table VRT a decoded dataset reads.
.vrt_of <- function(ds) {
  g <- ds@graph
  for (i in graph_ids(g)) {
    n <- graph_get(g, i)
    if (S7::S7_inherits(n, SourceNode)) return(n@path)
  }
}

# Keep the decode from reading codes itself, so every read takes the VRT.
with_no_decode_read <- function(expr) {
  ns <- asNamespace("garry")
  orig <- get(".rio_direct_spec", envir = ns)
  unlockBinding(".rio_direct_spec", ns)
  assign(
    ".rio_direct_spec",
    function(..., decode = FALSE) if (decode) NULL else orig(...),
    envir = ns
  )
  on.exit({
    assign(".rio_direct_spec", orig, envir = ns)
    lockBinding(".rio_direct_spec", ns)
  })
  force(expr)
}

.warp_args <- function(ds) {
  p <- plan_lazy(stack_bands(ds))
  ws <- Filter(function(s) s@kind == "warp", p@stages)
  if (!length(ws)) {
    return(NULL)
  }
  .stage_read_args(p@graph, ws[[1L]])
}

test_that("decoded codes read through the lookup table, nodata NaN", {
  f <- .coded()
  ds <- lazy_dataset(f, decode = dequantize_aef)
  expect_identical(stack_bands(ds)@grid@dtype, "f32")
  got <- collect(stack_bands(ds), distributed = FALSE)
  for (b in 1:3) {
    expect_identical(unname(got[,, b]), .decoded(.codes_of(f, b)))
  }
  # the codes decode directly, on their own grid or onto a window of it
  p <- plan_lazy(stack_bands(ds))
  expect_length(
    .stage_read_args(p@graph, p@stages[[1L]])$decim$decode$table,
    256L
  )
  ds10 <- lazy_dataset(f, .g10_in(), decode = dequantize_aef)
  expect_length(.warp_args(ds10)$decim$decode$table, 256L)
  inner <- got[2:8, 2:11, ]
  expect_equal(
    collect(stack_bands(ds10), distributed = FALSE),
    inner,
    tolerance = 0,
    ignore_attr = "gis"
  )
  # as the lookup-table VRT decodes them
  expect_equal(
    with_no_decode_read(collect(stack_bands(ds10), distributed = FALSE)),
    inner,
    tolerance = 0,
    ignore_attr = "gis"
  )
})

test_that("average takes the mean of decoded valid codes", {
  f <- .coded()
  ds <- lazy_dataset(f, .g30(), resampling = "average", decode = dequantize_aef)
  expect_false(is.null(.warp_args(ds)$decim$decode))
  got <- collect(stack_bands(ds), distributed = FALSE)
  for (b in 1:3) {
    dv <- .decoded(.codes_of(f, b))
    want <- matrix(NaN, 3L, 4L)
    for (r in 1:3) {
      for (q in 1:4) {
        blk <- t(dv[(3 * r - 2):(3 * r), (3 * q - 2):(3 * q)]) # row by row
        ok <- !is.nan(blk)
        # summed in order in double, as the reader sums
        if (any(ok)) want[r, q] <- .f32(Reduce(`+`, blk[ok]) / sum(ok))
      }
    }
    expect_identical(unname(got[,, b]), want)
    # the all-nodata block stays NaN
    expect_true(is.nan(got[1L, 1L, b]))
  }
  # GDAL's average of the lookup-table VRT agrees to f32 rounding
  vrt <- .vrt_of(ds)
  expect_match(vrt, "\\.vrt$")
  for (b in 1:3) {
    ref <- gdal_read_window(
      vrt,
      b,
      0L,
      0L,
      4L,
      3L,
      decim = list(fx = 3L, fy = 3L, x_off = 0L, y_off = 0L, resamp = "AVERAGE")
    )
    expect_equal(unname(got[,, b]), ref, tolerance = 1e-6)
  }
})

test_that("reads the decode cannot serve take the lookup-table VRT", {
  f <- .coded()
  # bilinear at the source's pixel centres returns the decoded codes
  ds <- lazy_dataset(
    f,
    .g10(),
    resampling = "bilinear",
    decode = dequantize_aef
  )
  expect_null(.warp_args(ds)$decim$decode)
  got <- collect(stack_bands(ds), distributed = FALSE)
  expect_identical(unname(got[,, 2L]), .decoded(.codes_of(f, 2L)))
  # a decimating near read picks the code GDAL picks, then decodes it
  g20 <- grid_spec("EPSG:32736", c(500000, 8599920, 500120, 8600000), res = 20)
  fast <- collect(
    stack_bands(lazy_dataset(f, g20, decode = dequantize_aef)),
    distributed = FALSE
  )
  slow <- with_no_decode_read(
    collect(
      stack_bands(lazy_dataset(f, g20, decode = dequantize_aef)),
      distributed = FALSE
    )
  )
  expect_identical(fast, slow)
})

test_that("pixel-interleaved and south-up codes decode as band-interleaved ones do", {
  want <- collect(
    stack_bands(lazy_dataset(
      .coded(),
      .g30(),
      resampling = "average",
      decode = dequantize_aef
    )),
    distributed = FALSE
  )
  pix <- lazy_dataset(
    .coded("PIXEL"),
    .g30(),
    resampling = "average",
    decode = dequantize_aef
  )
  expect_identical(collect(stack_bands(pix), distributed = FALSE), want)
  # south-up: a direct read on its own pixels, the VRT coarser
  s10 <- lazy_dataset(
    .coded(south_up = TRUE),
    .g10_in(),
    decode = dequantize_aef
  )
  expect_true(.warp_args(s10)$decim$flip)
  n10 <- lazy_dataset(.coded(), .g10_in(), decode = dequantize_aef)
  expect_identical(
    collect(stack_bands(s10), distributed = FALSE),
    collect(stack_bands(n10), distributed = FALSE)
  )
  s30 <- lazy_dataset(
    .coded(south_up = TRUE),
    .g30(),
    resampling = "average",
    decode = dequantize_aef
  )
  # a decoded read flips full rows itself, so it decimates south-up too
  expect_false(is.null(.warp_args(s30)$decim$decode))
  expect_equal(
    collect(stack_bands(s30), distributed = FALSE),
    want,
    tolerance = 1e-6
  )
})

test_that("a pooled decoded write matches the single-process one", {
  skip_on_cran()
  ds <- function() {
    stack_bands(lazy_dataset(
      .coded(),
      .g30(),
      resampling = "average",
      decode = dequantize_aef
    ))
  }
  f1 <- withr::local_tempfile(fileext = ".tif")
  f2 <- withr::local_tempfile(fileext = ".tif")
  write_tif(ds(), f2, distributed = FALSE)
  local_pools(2, 1)
  write_tif(ds(), f1, distributed = TRUE)
  rd <- function(f) {
    d <- methods::new(gdalraster::GDALRaster, f)
    on.exit(d$close())
    lapply(1:3, function(b) d$read(b, 0L, 0L, 4L, 3L, 4L, 3L))
  }
  expect_identical(rd(f1), rd(f2))
})

test_that("decode refuses what it cannot read", {
  f <- .coded()
  expect_error(
    lazy_dataset(fixture_gradient_f32(), decode = dequantize_aef),
    "8-bit codes"
  )
  expect_error(
    lazy_dataset(f, decode = dequantize_aef, scale = 2),
    "do not combine"
  )
  expect_error(lazy_dataset(f, decode = "aef"), "must be a function")
  expect_error(lazy_dataset(f, decode = function(x) 1), "one number per code")
  expect_error(lazy_dataset(f, decode = function(x) 1 / x), "finite Float32")
  expect_error(
    lazy_dataset(f, decode = dequantize_aef, nodata = -127),
    "differs from the file"
  )
  expect_identical(
    collect(
      lazy_source(f, band = 2L, decode = dequantize_aef),
      distributed = FALSE
    ),
    .decoded(.codes_of(f, 2L)),
    ignore_attr = TRUE
  )
})

test_that("rows of codes decode and average in C", {
  tab <- c(NaN, 0.5, 1, 2) # codes -1 (nodata), 0, 1, 2
  out <- .Call("garry_alloc_double", 2, PACKAGE = "garry")
  # a 2 x 1 cell slab of 2 x 2 blocks: rows (0, 1, 2, 2) and (-1, NA, 1, 0)
  codes <- c(0L, 1L, 2L, 2L, -1L, NA, 1L, 0L)
  .Call(
    "garry_decode_into",
    out,
    0,
    codes,
    c(-1, 2, 2, 2, 1, 0, 0),
    tab,
    PACKAGE = "garry"
  )
  expect_identical(out, c((0.5 + 1) / 2, (2 + 2 + 1 + 0.5) / 4))
  expect_error(
    .Call(
      "garry_decode_into",
      out,
      1,
      codes,
      c(-1, 2, 2, 2, 1, 0, 0),
      tab,
      PACKAGE = "garry"
    ),
    "do not decode"
  )
})

# A Byte file of codes 0 and 200 only, 96 x 96 at 10 m, with overviews
# built by averaging: an overview holds codes no pixel has.
.overviewed <- function(south_up = FALSE) {
  f <- file.path(
    tempdir(),
    paste0("garry-overviewed", if (south_up) "-s", ".tif")
  )
  if (!file.exists(f)) {
    set.seed(3)
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
    ds$setGeoTransform(
      if (south_up) {
        c(500000, 10, 0, 8599040, 0, 10)
      } else {
        c(500000, 10, 0, 8600000, 0, -10)
      }
    )
    ds$write(1L, 0L, 0L, 96L, 96L, sample(c(0L, 200L), 9216L, replace = TRUE))
    ds$close()
    ds <- methods::new(gdalraster::GDALRaster, f, read_only = FALSE)
    ds$buildOverviews("AVERAGE", c(2L, 4L), 1L)
    ds$close()
  }
  f
}

test_that("no read decodes an overview's resampled codes", {
  sq <- function(x) x^2
  for (su in c(FALSE, TRUE)) {
    f <- .overviewed(su)
    g10 <- grid_spec(
      "EPSG:32736",
      c(500000, 8599040, 500960, 8600000),
      res = 10
    )
    full <- unname(collect(lazy_source(f, decode = sq), distributed = FALSE))
    expect_true(all(full %in% c(0, 40000)))
    # 3x average onto aligned pixels, directly and through the VRT
    g30 <- grid_spec(
      "EPSG:32736",
      c(500000, 8599040, 500960, 8600000),
      res = 30
    )
    want <- .block_mean_dec(full, 3L)
    for (fast in c(TRUE, FALSE)) {
      run <- function() {
        collect(
          stack_bands(lazy_dataset(
            f,
            g30,
            resampling = "average",
            decode = sq
          )),
          distributed = FALSE
        )
      }
      got <- if (fast) run() else with_no_decode_read(run())
      expect_equal(unname(got), want, tolerance = 1e-6, ignore_attr = TRUE)
    }
    # an unaligned average warps the VRT, at full resolution
    g15 <- grid_spec(
      "EPSG:32736",
      c(500005, 8599045, 500905, 8599945),
      res = 30
    )
    got <- collect(
      stack_bands(lazy_dataset(f, g15, resampling = "average", decode = sq)),
      distributed = FALSE
    )
    expect_true(all(got >= 0 & got <= 40000, na.rm = TRUE))
    # a decimating near read picks codes, never averaged ones
    g40 <- grid_spec(
      "EPSG:32736",
      c(500000, 8599040, 500960, 8600000),
      res = 40
    )
    fast <- collect(
      stack_bands(lazy_dataset(f, g40, decode = sq)),
      distributed = FALSE
    )
    slow <- with_no_decode_read(collect(
      stack_bands(lazy_dataset(f, g40, decode = sq)),
      distributed = FALSE
    ))
    expect_true(all(fast %in% c(0, 40000)))
    expect_identical(fast, slow)
  }
})

test_that("a mask band reads as stored, and the VRT keeps the codes' blocks", {
  f <- file.path(tempdir(), "garry-coded-mask.tif")
  if (!file.exists(f)) {
    ds <- gdalraster::create(
      "GTiff",
      f,
      40L,
      30L,
      2L,
      "Byte",
      options = c("TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"),
      return_obj = TRUE
    )
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:32736"))
    ds$setGeoTransform(c(500000, 10, 0, 8600300, 0, -10))
    ds$setDescription(1L, "v")
    ds$setDescription(2L, "qa")
    ds$write(1L, 0L, 0L, 40L, 30L, rep(c(10L, 20L, 30L), 400L))
    ds$write(2L, 0L, 0L, 40L, 30L, rep(c(0L, 8L), 600L))
    ds$close()
  }
  ds <- lazy_dataset(f, decode = function(x) x / 100, mask_asset = "qa")
  got <- collect(stack_bands(ds), distributed = FALSE)
  expect_setequal(unique(as.vector(got[,, 2L])), c(0, 8))
  expect_setequal(unique(as.vector(got[,, 1L])), .f32(c(0.1, 0.2, 0.3)))
  # chunks snap to the codes' blocks, not the VRT's
  src <- graph_get(ds@graph, min(graph_ids(ds@graph)))
  expect_identical(src@block_dim, gdal_grid_spec(f)$block_dim)
  x <- lazy_source(f, decode = function(x) x / 100)
  expect_identical(
    graph_get(x@graph, x@node_id)@block_dim,
    gdal_grid_spec(f)$block_dim
  )
})

test_that("decode refuses bands with different nodata codes, NA nodata and f32 overflow", {
  # GeoTIFF keeps one nodata a file: a VRT of two files holds one each
  f <- file.path(tempdir(), "garry-coded-ndmix.vrt")
  if (!file.exists(f)) {
    one <- function(name, nd) {
      p <- file.path(tempdir(), name)
      ds <- gdalraster::create(
        "GTiff",
        p,
        4L,
        3L,
        1L,
        "Int8",
        return_obj = TRUE
      )
      ds$setProjection(gdalraster::srs_to_wkt("EPSG:32736"))
      ds$setGeoTransform(c(500000, 10, 0, 8600030, 0, -10))
      ds$setNoDataValue(1L, nd)
      ds$close()
      p
    }
    gdalraster::buildVRT(
      f,
      c(one("garry-nd-a.tif", -128), one("garry-nd-b.tif", 5)),
      cl_arg = "-separate",
      quiet = TRUE
    )
  }
  expect_error(lazy_dataset(f, decode = dequantize_aef), "one nodata code")
  expect_error(
    lazy_dataset(.coded(), decode = dequantize_aef, nodata = NA),
    "a number"
  )
  expect_error(
    lazy_dataset(.coded(), decode = function(x) x * 1e300),
    "finite Float32"
  )
})
