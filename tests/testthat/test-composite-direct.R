# The DEFAULT distributed composite route (.cd_spec ->
# .execute_composite_direct / the fetch-ordered pipeline): what selects it
# and how its parts fail. test-route-matrix.R holds its results to plain R;
# the strip decomposition and morphology live in test-gd-tail.R.

test_that(".gd_compute_budget sends a heavy single band to the scheduler", {
  p <- collect(.gg_masked_composite(single = TRUE), plan_only = TRUE)
  expect_identical(.cd_spec(p)$n_bands, 1L)
  # Above the budget .cd_spec refuses a single band, whose whole-grid
  # kernel would run in the host; a multi-band pipeline needs no guard.
  testthat::local_mocked_bindings(.gd_compute_budget = 1)
  expect_null(.cd_spec(p))
  expect_null(.gd_decompose(p))
  expect_false(is.null(.cd_spec(collect(.gg_masked_composite(), plan_only = TRUE))))
})

test_that("GTI sources the fast routes cannot read themselves fall through", {
  gA <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
  src <- function(filter = "slice = 's1'", sort_asc = TRUE, band = 1L) {
    lazy_source(
      paste0("GTI:", gA),
      band = band,
      open_options = gti_open_options(
        .gg_grid,
        filter = filter,
        sort_field = "datetime",
        sort_asc = sort_asc
      ),
      grid = .gg_grid,
      block_dim = c(60L, 40L)
    )
  }
  n <- function(lr) graph_get(lr@graph, lr@node_id)
  expect_true(.gd_source_ok(n(src())))
  expect_false(.gd_source_ok(n(src(filter = "datetime > '2020'"))))
  expect_false(.gd_source_ok(n(src(sort_asc = FALSE))))
  expect_identical(.gti_slice_of("FILTER=slice = 's1'"), "s1")
  expect_null(.gti_slice_of("FILTER=slice = 's1' AND x = 2"))
  expect_true(is.na(.gti_slice_of(character(0))))
})

test_that("a failed warp is the run's failure", {
  bad <- structure("slice warp failed: a.tif", class = c("miraiError", "errorValue"))
  err <- expect_error(.gd_check_fetch(list(list(tw = 1), bad), "band 1"), class = "garry_read_error")
  expect_match(conditionMessage(err), "1/2 band 1 warps failed", fixed = TRUE)
  expect_match(conditionMessage(err), "a.tif", fixed = TRUE)
  expect_no_error(.gd_check_fetch(list(list(tw = 1)), "band 1"))
})

test_that("a failed slice warp names its source and leaves no slice", {
  withr::local_options(garry.read_retry = 0L)
  bin <- withr::local_tempfile(fileext = ".bin")
  j <- list(locs = "/nonexistent/ghost.tif", dt = 1, nodata = numeric(0), resampling = "near", bin = bin)
  k <- list(nx = 4L, ny = 4L, gtstr = "0/10/0/40/0/-10", wkt = gdalraster::srs_to_wkt("EPSG:3857"))
  err <- expect_error(.gdal_hushed(.cd_fetch_warp(j, k), .gdal_missing(j$locs)),
                      class = "garry_read_error")
  expect_match(conditionMessage(err), "ghost.tif", fixed = TRUE)
  expect_false(file.exists(bin))
})

test_that("an aligned slice translates to the plane a warp leaves", {
  tif <- function(dtype, values, nodata = NULL) {
    f <- withr::local_tempfile(fileext = ".tif", .local_envir = parent.frame(2))
    ds <- gdalraster::create("GTiff", f, 40L, 30L, 1L, dtype, return_obj = TRUE)
    ds$setGeoTransform(c(500000, 30, 0, 5000000, 0, -30))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:32633"))
    if (!is.null(nodata)) ds$setNoDataValue(1L, nodata)
    ds$write(1L, 0L, 0L, 40L, 30L, values)
    ds$close()
    f
  }
  plane <- function(bin, n) readBin(bin, "numeric", n = n, size = 4)
  grid <- function(f, y0, rows, x0 = 0L, nx = 40L) {
    g <- lazy_source(f)@grid
    g <- grid_spec(
      g@crs,
      extent = c(500000 + x0 * 30, 5000000 - (y0 + rows) * 30, 500000 + (x0 + nx) * 30, 5000000 - y0 * 30),
      dims = c(nx, rows),
      dtype = "f32"
    )
    .gd_rows_K(g, 0L, rows)
  }
  both <- function(f, k, resampling, nodata = numeric(0)) {
    bin <- withr::local_tempfile(fileext = ".bin", .local_envir = parent.frame())
    j <- list(locs = f, dt = 1, band = 1L, nodata = nodata, resampling = resampling, bin = bin)
    expect_true(gdal_translate_plane(f, 1L, k$grid, resampling, nodata, bin))
    expect_identical(list.files(dirname(bin), basename(sub("\\.bin$", "", bin))), basename(bin))
    read <- plane(bin, k$nx * k$ny)
    testthat::local_mocked_bindings(gdal_translate_plane = function(...) FALSE)
    .cd_fetch_warp(j, k)
    expect_identical(read, plane(bin, k$nx * k$ny))
  }
  v <- ((seq_len(1200) * 37L) %% 2000L) - 500L
  v[seq(1, 1200, by = 7)] <- -9999L
  i16 <- tif("Int16", v, -9999)
  for (r in c("near", "bilinear", "cubic")) {
    both(i16, grid(i16, 0L, 30L), r)
    both(i16, grid(i16, 0L, 30L), r, -9999)
  }
  # a block of rows, and a crop, read their own window
  both(i16, grid(i16, 12L, 9L), "bilinear", -9999)
  both(i16, grid(i16, 5L, 20L, 7L, 25L), "bilinear", -9999)
  # no sentinel at all, on floats with NaN in them
  w <- as.numeric(seq_len(1200)) / 3
  w[c(5, 80, 900)] <- NaN
  both(tif("Float32", w), grid(i16, 0L, 30L), "bilinear")

  bin <- withr::local_tempfile(fileext = ".bin")
  k <- grid(i16, 0L, 30L)
  # kernels that move cells on a file's own pixels are the warper's
  expect_false(gdal_translate_plane(i16, 1L, k$grid, "cubicspline", -9999, bin))
  expect_false(gdal_translate_plane(i16, 1L, k$grid, "rms", -9999, bin))
  # so is a float sentinel, which the warper masks within a tolerance
  w2 <- as.numeric(seq_len(1200))
  w2[3] <- -9999
  float_nd <- tif("Float32", w2, -9999)
  expect_false(gdal_translate_plane(float_nd, 1L, k$grid, "near", numeric(0), bin))
  expect_false(gdal_translate_plane(float_nd, 1L, k$grid, "near", -9999, bin))
  # a decimating target, and rows stored from the south
  coarse <- grid_spec(k$grid@crs, extent = c(500000, 4999100, 501200, 5000000), dims = c(20L, 15L), dtype = "f32")
  expect_false(gdal_translate_plane(i16, 1L, coarse, "near", -9999, bin))
  up <- withr::local_tempfile(fileext = ".tif")
  ds <- gdalraster::create("GTiff", up, 40L, 30L, 1L, "Int16", return_obj = TRUE)
  ds$setGeoTransform(c(500000, 30, 0, 4999100, 0, 30))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32633"))
  ds$write(1L, 0L, 0L, 40L, 30L, v)
  ds$close()
  expect_false(gdal_translate_plane(up, 1L, k$grid, "near", numeric(0), bin))
  # an unaligned target, and a window past the file, are the warper's
  shifted <- grid_spec(k$grid@crs, extent = c(500010, 4999100, 501210, 5000000), dims = c(40L, 30L), dtype = "f32")
  expect_false(gdal_translate_plane(i16, 1L, shifted, "bilinear", -9999, bin))
  past <- grid_spec(k$grid@crs, extent = c(500000, 4999100, 501500, 5000000), dims = c(50L, 30L), dtype = "f32")
  expect_false(gdal_translate_plane(i16, 1L, past, "bilinear", -9999, bin))
  # a sentinel the file does not share is the warper's too: it masks only the node's
  expect_false(gdal_translate_plane(i16, 1L, k$grid, "bilinear", -1, bin))
  expect_false(file.exists(bin))

  # a real one-item job that cannot be read names its source and leaves nothing
  withr::local_options(garry.read_retry = 0L)
  ghost <- "/nonexistent/ghost.tif"
  job <- list(locs = ghost, dt = 1, band = 1L, nodata = -9999, resampling = "near", bin = bin)
  err <- expect_error(.gdal_hushed(.cd_fetch_warp(job, k), .gdal_missing(ghost)),
                      class = "garry_read_error")
  expect_match(conditionMessage(err), "ghost.tif", fixed = TRUE)
  expect_false(file.exists(bin))
  # a translate that stops part way leaves no plane and no sidecars
  testthat::local_mocked_bindings(gdal_translate_file = function(src, dst, cl) {
    writeBin(raw(100), dst)
    writeLines("ENVI", sub("\\.bin$", ".hdr", dst))
    stop("GDAL Error 1: read failed")
  })
  expect_error(suppressMessages(gdal_translate_plane(i16, 1L, k$grid, "near", -9999, bin)), class = "garry_read_error")
  expect_identical(list.files(dirname(bin), basename(sub("\\.bin$", "", bin))), character(0))
  # the source's handle goes with the fetch, and its blocks with it
  expect_false(any(grepl(basename(i16), names(.gdal_cache$handles), fixed = TRUE)))
})

local({
  local_pools(2, 1, gdal_config = TRUE)

  test_that("a daemon translates an aligned slice under its own GDAL config", {
    f <- withr::local_tempfile(fileext = ".tif")
    ds <- gdalraster::create("GTiff", f, 40L, 30L, 1L, "Int16", return_obj = TRUE)
    ds$setGeoTransform(c(500000, 30, 0, 5000000, 0, -30))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:32633"))
    ds$setNoDataValue(1L, -9999)
    v <- (seq_len(1200) %% 500L) - 250L
    v[seq(1, 1200, by = 9)] <- -9999L
    ds$write(1L, 0L, 0L, 40L, 30L, v)
    ds$close()
    bin <- withr::local_tempfile(fileext = ".bin")
    fetch <- function(j, k) {
      mirai::collect_mirai(mirai::mirai(
        {
          res <- asNamespace("garry")$.cd_fetch_warp(j, k)
          res$listing <- gdalraster::get_config_option("GDAL_DISABLE_READDIR_ON_OPEN")
          res
        },
        j = j, k = k, .compute = "garry_read"
      ))
    }
    g <- lazy_source(f)@grid
    k <- .gd_rows_K(g, 0L, 30L)
    j <- list(locs = f, dt = 1, band = 1L, nodata = -9999, resampling = "bilinear", bin = bin)
    res <- fetch(j, k)
    expect_identical(res$how, "translate")
    # the config a daemon's later opens rely on comes back
    expect_identical(res$listing, "EMPTY_DIR")
    want <- as.numeric(matrix(v, 40L, 30L))
    want[want == -9999] <- NaN
    expect_identical(readBin(bin, "numeric", n = 1200L, size = 4), want)

    # half a pixel off, the same slice warps, on the same daemon config
    off <- grid_spec(g@crs, extent = g@extent + c(15, 0, 15, 0), dims = c(40L, 30L), dtype = "f32")
    res <- fetch(j, .gd_rows_K(off, 0L, 30L))
    expect_identical(res$how, "warp")
    warped <- readBin(bin, "numeric", n = 1200L, size = 4)
    testthat::local_mocked_bindings(gdal_translate_plane = function(...) FALSE)
    .cd_fetch_warp(j, .gd_rows_K(off, 0L, 30L))
    expect_identical(readBin(bin, "numeric", n = 1200L, size = 4), warped)
    # and so do two items, even on the grid's own pixels
    res <- fetch(modifyList(j, list(locs = c(f, f), dt = 1:2)), k)
    expect_identical(res$how, "warp")
  })
})

# Masked reduces built by hand over GTI slices: `map` masks a band's slice with
# its mask, and `qa` makes that mask from the slice's QA read. Slice s1 is
# flagged `code` on its top half and s2 is clear, so a mask that works takes s1's
# value off the top half. One band for each of `vals`.
.dr_plan <- function(map, vals = c(5, 8), op = "max", nan_rm = FALSE, type = "Float32",
                     dtype = "f32", code = 2,
                     qa = function(q) lazy_map(q, fn = function(v) v > 1, dtype = "f32")) {
  q1 <- matrix(0, 40L, 60L)
  q1[1:20, ] <- code
  gQ <- .gg_gti(list(s1 = q1, s2 = q1 * 0), type)
  g <- graph_new()
  masks <- lapply(c("s1", "s2"), function(s) qa(.gg_slice(gQ, s, g, dtype)))
  band <- function(v) {
    gti <- .gg_gti(list(s1 = matrix(v, 40L, 60L), s2 = matrix(v + 1, 40L, 60L)))
    slices <- lapply(c("s1", "s2"), function(s) .gg_slice(gti, s, g))
    reduce_over(lazy_stack(Map(map, slices, masks)), op, "t", nan_rm = nan_rm)
  }
  bands <- lapply(vals, band)
  if (length(bands) == 1L) {
    return(bands[[1L]])
  }
  lazy_stack(stats::setNames(bands, paste0("V", seq_along(bands))), along = "band")
}

local({
  local_pools(2, 2)

  # One value per band, or a (y, x, band) array of them.
  cells <- function(vals) {
    if (length(vals) == 1L) {
      return(matrix(vals, 40L, 60L))
    }
    array(rep(vals, each = 2400L), c(40L, 60L, length(vals)))
  }

  test_that("a masked map that declares f32 stays on the route", {
    thirds <- function(v, m) lazy_map(v, m, fn = function(a, b) g_ifelse(b > 0.5, 0, a / 3), dtype = "f32")
    got <- collect(.dr_plan(thirds), distributed = TRUE)
    expect_identical(garry_last_route(), "composite_direct")
    .expect_cells(unclass(got), .as_f32(cells(c(6, 9) / 3)))
  })

  test_that("a masked map at another dtype leaves the route and holds it, per slice", {
    third <- function(v, m) lazy_map(v, m, fn = function(a, b) g_ifelse(b > 0.5, 0, a / 3), dtype = "i16")
    for (vals in list(c(4, 7), 4)) {
      got <- collect(.dr_plan(third, vals), distributed = TRUE)
      expect_identical(garry_last_route(), "scheduler")
      .expect_cells(unclass(got), cells(trunc((vals + 1) / 3)))
    }
    # no dtype named: the kernel's own i32 is the declaration
    whole <- function(v, m) lazy_map(v, m, fn = function(a, b) g_cast(g_ifelse(b > 0.5, 0, a), "i32"))
    x <- .dr_plan(whole)
    expect_identical(x@grid@dtype, "i32")
    got <- collect(x, distributed = TRUE)
    expect_identical(garry_last_route(), "scheduler")
    .expect_cells(unclass(got), cells(c(6, 9)))
  })

  # Cells of .dr_plan() over bands of 100 and 200: s2's value where the mask
  # takes s1's away, their median elsewhere.
  masked <- function(top = TRUE) {
    band <- function(v) {
      m <- matrix(v + 0.5, 40L, 60L)
      if (top) m[1:20, ] <- v + 1
      m
    }
    array(c(band(100), band(200)), c(40L, 60L, 2L))
  }
  nan_map <- function(v, m) lazy_map(v, m, fn = function(a, b) g_ifelse(b > 0.5, NaN, a))
  median_of <- function(...) .dr_plan(nan_map, c(100, 200), "median", TRUE, ...)

  test_that("an integer or logical mask masks on the route, whatever its width", {
    qa <- list(
      u16 = list(type = "UInt16", code = 30000, thr = 21824L),
      u8 = list(type = "Byte", code = 200, thr = 100L),
      i8 = list(type = "Int8", code = 100, thr = 50L),
      i16 = list(type = "Int16", code = 200, thr = 100L)
    )
    for (dt in names(qa)) {
      thr <- qa[[dt]]$thr
      logical_map <- function(q) lazy_map(q, fn = function(v) v > thr)
      x <- median_of(type = qa[[dt]]$type, dtype = dt, code = qa[[dt]]$code, qa = logical_map)
      got <- collect(x, distributed = TRUE)
      expect_identical(garry_last_route(), "composite_direct", info = dt)
      .expect_cells(unclass(got), masked(), info = dt)
    }
    # one band runs its mask inside its one kernel, with no file
    q16 <- function(q) lazy_map(q, fn = function(v) v > 21824L)
    one <- .dr_plan(nan_map, 100, "median", TRUE, type = "UInt16", dtype = "u16", code = 30000, qa = q16)
    got <- collect(one, distributed = TRUE)
    expect_identical(garry_last_route(), "composite_direct")
    .expect_cells(unclass(got), masked()[, , 1L])
  })

  test_that("a predicate mask masks on the route", {
    pred <- function(q) lazy_map(q, fn = function(v) v > 122L, dtype = "pred")
    got <- collect(median_of(type = "UInt16", dtype = "u16", code = 200, qa = pred), distributed = TRUE)
    expect_identical(garry_last_route(), "composite_direct")
    .expect_cells(unclass(got), masked())
  })

  test_that("a band kernel reads a mask at the mask's dtype", {
    # g_bitand refuses a float, and `!` an integer
    bits <- function(v, m) lazy_map(v, m, fn = function(a, b) g_ifelse(g_bitand(b, 1L) > 0L, NaN, a))
    flagged <- function(q) lazy_map(q, fn = function(v) v > 1L)
    x <- .dr_plan(bits, c(100, 200), "median", TRUE, type = "Int16", dtype = "i16", qa = flagged)
    expect_identical(x@grid@dtype, "f32")
    got <- collect(x, distributed = TRUE)
    expect_identical(garry_last_route(), "composite_direct")
    .expect_cells(unclass(got), masked())

    negated <- function(v, m) lazy_map(v, m, fn = function(a, b) g_ifelse(!b, a, NaN))
    pred <- function(q) lazy_map(q, fn = function(v) v > 1, dtype = "pred")
    got <- collect(.dr_plan(negated, c(100, 200), "median", TRUE, qa = pred), distributed = TRUE)
    expect_identical(garry_last_route(), "composite_direct")
    .expect_cells(unclass(got), masked())
  })

  test_that("a mask f32 cannot hold leaves the route", {
    # 2^24 + 1 rounds to 2^24 in f32, so the file would lose the flag's low bit
    wide <- function(q) lazy_map(q, fn = function(v) g_cast(v, "i32") * 8388608L + 1L)
    odd <- function(v, m) lazy_map(v, m, fn = function(a, b) g_ifelse(g_bitand(b, 1L) > 0L, a, NaN))
    x <- .dr_plan(odd, c(100, 200), "median", TRUE, type = "Int16", dtype = "i16", qa = wide)
    got <- collect(x, distributed = TRUE)
    expect_identical(garry_last_route(), "scheduler")
    .expect_cells(unclass(got), masked(top = FALSE))
    # f64 too, so a threshold reads the value the chain declared
    close <- function(q) lazy_map(q, fn = function(v) g_cast(v, "f64") + 0.5 + 1e-12, dtype = "f64")
    above <- function(v, m) lazy_map(v, m, fn = function(a, b) g_ifelse(b > 0.5, NaN, a))
    got <- collect(.dr_plan(above, c(100, 200), "median", TRUE, qa = close), distributed = TRUE)
    expect_identical(garry_last_route(), "scheduler")
    expect_true(all(is.nan(got)))
  })

  test_that("two mask chains that differ only by a dtype keep their own kernels", {
    third <- function(v) v / 3
    above_1 <- function(v) v > 1
    # 4 / 3 survives a 1 only if the first map stays float
    chain <- function(dt) {
      function(q) lazy_map(lazy_map(lazy_map(q, fn = third, dtype = dt), fn = above_1, dtype = "f32"),
                           fn = function(v) v, dtype = "f32")
    }
    plan <- function(dt) median_of(code = 4, qa = chain(dt))
    expect_false(identical(
      .cd_chain_sig(.cd_spec(collect(plan("i16"), plan_only = TRUE))$mask_chain),
      .cd_chain_sig(.cd_spec(collect(plan("f32"), plan_only = TRUE))$mask_chain)
    ))
    .expect_cells(unclass(collect(plan("i16"), distributed = TRUE)), masked(top = FALSE))
    expect_identical(garry_last_route(), "composite_direct")
    .expect_cells(unclass(collect(plan("f32"), distributed = TRUE)), masked())
    expect_identical(garry_last_route(), "composite_direct")
  })

  test_that("a mask kernel run over one QA dtype serves no other", {
    shared <- function(v) v > 144L
    logical_map <- function(q) lazy_map(q, fn = shared)
    for (ty in list(c("Int16", "i16"), c("Float32", "f32"), c("UInt16", "u16"))) {
      got <- collect(median_of(type = ty[[1L]], dtype = ty[[2L]], code = 200, qa = logical_map),
                     distributed = TRUE)
      expect_identical(garry_last_route(), "composite_direct", info = ty[[2L]])
      .expect_cells(unclass(got), masked(), info = ty[[2L]])
    }
  })

  test_that("a logical masked map stores 0/1 on the route", {
    above <- function(v, m) lazy_map(v, m, fn = function(a, b) a > b)
    for (vals in list(c(5, 8), 5)) {
      x <- .dr_plan(above, vals)
      expect_identical(x@grid@dtype, "f32")
      got <- collect(x, distributed = TRUE)
      expect_identical(garry_last_route(), "composite_direct")
      .expect_cells(unclass(got), cells(rep(1, length(vals))))
    }
  })
})

test_that("a composite warps onto the declared grid, to the last digit", {
  gti <- .gg_gti(list(s1 = .gg_val(0)))
  p <- plan_lazy(.gg_slice(gti, "s1", graph_new()))
  g <- grid_spec("EPSG:3857",
                 extent = c(-13627665.27123, 500010.123456, -13627065.27123, 500410.123456),
                 dims = c(60L, 40L), dtype = "f32")
  gt <- as.numeric(strsplit(.gd_build_jobs(p, g, tempdir())$K$gtstr, "/")[[1L]])
  expect_identical(gt, g@transform)
})

test_that("a slice with no items fails as a read, saying so", {
  expect_error(
    garry:::.cd_fetch_warp(list(locs = character(0)), list(nx = 1L, ny = 1L)),
    "no items",
    class = "garry_read_error"
  )
})
