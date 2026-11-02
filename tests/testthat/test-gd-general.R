# Warp-on-read plans the composite fast path (.cd_spec) does not match: the
# reduce decomposition (.gd_decompose, .execute_gd_reduce) must agree with the
# general scheduler (execute_plan_mirai) and, byte for byte, with the WHOLE
# reachable IR compiled into one kernel, on derived bands, band math, focal,
# and nested reduce -> map -> reduce. All three answer to a value from plain R.


# GTI fixtures (.gg_grid / .gg_gti / .gg_slice / .gg_val) and the strict
# comparator live in helper-gti.R, shared with the composite-direct and
# route-matrix gates.

# Two two-slice composites (bands A, B) on one shared graph.
.gg_composites <- function() {
  gA <- .gg_gti(list(s1 = .gg_val(0),   s2 = .gg_val(10)))
  gB <- .gg_gti(list(s1 = .gg_val(100), s2 = .gg_val(50)))
  g <- graph_new()
  list(A = reduce_over(lazy_stack(list(.gg_slice(gA, "s1", g),
                                       .gg_slice(gA, "s2", g))), "median", "t"),
       B = reduce_over(lazy_stack(list(.gg_slice(gB, "s1", g),
                                       .gg_slice(gB, "s2", g))), "median", "t"))
}

# A two-band upper stack over two two-slice composites on an `nx` x `ny` grid:
# the sum of bases 0 and 100 at each cell, and their difference.
.gg_narrow_stack <- function(nx, ny) {
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, nx * 10, ny * 10), dims = c(nx, ny), dtype = "f32")
  gti <- function(base) {
    ent <- do.call(rbind, lapply(1:2, function(i) {
      f <- tempfile(fileext = ".tif")
      d <- gdalraster::create("GTiff", f, nx, ny, 1, "Float32", return_obj = TRUE)
      d$setGeoTransform(c(0, 10, 0, ny * 10, 0, -10))
      d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
      d$write(1, 0, 0, nx, ny, base + i + seq_len(nx * ny))
      d$close()
      data.frame(location = f, slice = paste0("s", i), datetime = paste0("s", i),
                 xmin = 0, ymin = 0, xmax = nx * 10, ymax = ny * 10)
    }))
    path <- tempfile(fileext = ".gti.fgb")
    gti_index_create(ent, path, crs = "EPSG:3857")
    path
  }
  g <- graph_new()
  slice <- function(path, s) lazy_source(
    paste0("GTI:", path), graph = g, grid = grid, block_dim = c(nx, ny),
    open_options = gti_open_options(grid, filter = sprintf("slice = '%s'", s), sort_field = "datetime")
  )
  composite <- function(path) reduce_over(lazy_stack(list(slice(path, "s1"), slice(path, "s2"))), "median", "t")
  a <- composite(gti(0))
  b <- composite(gti(100))
  lazy_stack(list(sum = a + b, diff = b - a), along = "band")
}

# What those composites hold: each cell's median of its two slices.
.gg_a <- .gg_val(5)
.gg_b <- .gg_val(75)

# The oracle: every source warped, the whole IR replayed in one kernel.
.gg_whole_ir <- function(plan, gspec) {
  ny <- gspec$grid@dims[["y"]]
  nx <- gspec$grid@dims[["x"]]
  tmp <- .gd_tmp()
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  info <- .gd_warp_sources(plan, gspec$grid, tmp, .gd_log_open())
  dev <- .exec_device(gspec$device)
  h <- gspec$halo
  inputs <- lapply(gspec$input_nodes, function(id) {
    a <- g_upload_raw(
      readBin(info[[as.character(id)]]$bin, "raw", n = as.numeric(ny) * nx * 4),
      "f32",
      c(ny, nx),
      device = dev
    )
    n <- graph_get(plan@graph, id)
    if (length(n@scale) == 1L) {
      a <- a * n@scale + n@offset
    }
    if (h > 0L) g_pad(a, h, NaN) else a # radius-cell NaN edge boundary
  })
  res <- g_download(.gd_host_kernel(plan@graph, gspec, dev)(inputs))[[1L]]
  .gd_write_stack(res, gspec$grid, NULL, NULL, NULL, NULL)
}

.gg_equal <- function(x, want) {
  p <- plan_lazy(x)
  gsp <- .gd_spec(p)
  expect_false(is.null(gsp))                          # takes the general path
  expect_null(.cd_spec(p))                            # NOT the composite fast path
  gen   <- .gg_whole_ir(p, gsp)
  .gg_close(gen, want)
  .gg_close(gen, execute_plan_mirai(p), 1e-5)
  # Reduce-decomposition (the general path): compute the leaf temporal reduces
  # via the overlapped per-band pipeline, then run the upper IR on the 2D results
  # -- byte-identical to the whole-grid kernel.
  dc <- .gd_decompose(p)
  expect_false(is.null(dc))
  .gg_identical(.execute_gd_reduce(p, dc), gen)
}

test_that(".gd_write_stack splits bands without dropping a one-cell axis", {
  a <- array(as.numeric(1:10), c(2L, 1L, 5L))
  got <- .gd_write_stack(a, NULL, NULL, NULL, NULL, NULL)
  expect_identical(dim(got[[1L]]), c(1L, 5L))
  expect_identical(c(got[[2L]]), c(2, 4, 6, 8, 10))
  got <- .gd_write_stack(aperm(a, c(1L, 3L, 2L)), NULL, NULL, NULL, NULL, NULL)
  expect_identical(dim(got[[2L]]), c(5L, 1L))
  expect_identical(.gd_write_stack(array(7, c(1L, 1L, 1L)), NULL, NULL, NULL, NULL, NULL), matrix(7))
})

local({
  local_pools(2, 1)

  test_that("a derived band (map over reduces) runs warp-on-read == scheduler", {
    cs <- .gg_composites()
    .gg_equal((cs$A - cs$B) / (cs$A + cs$B),            # ndvi shape
              (.gg_a - .gg_b) / (.gg_a + .gg_b))
  })

  test_that("nested reduce -> map -> reduce runs warp-on-read == scheduler", {
    cs <- .gg_composites()
    ndvi <- (cs$A - cs$B) / (cs$A + cs$B)
    # a second derived band, then reduce over the band axis of the two
    top <- reduce_over(lazy_stack(list(ndvi, cs$A * 2 - cs$B), along = "band"),
                       "sum", "band")
    .gg_equal(top, (.gg_a - .gg_b) / (.gg_a + .gg_b) + .gg_a * 2 - .gg_b)
  })

  test_that("an integer leaf reaches its upper kernel at its dtype", {
    gti <- .gg_gti(list(s1 = matrix(65001, 40L, 60L), s2 = matrix(65001, 40L, 60L)), "UInt16")
    g <- graph_new()
    stack <- lazy_stack(list(.gg_slice(gti, "s1", g, "u16"), .gg_slice(gti, "s2", g, "u16")))
    leaf <- reduce_over(stack, "max", "t")
    # no f32 holds 65001001, and g_bitand refuses a float
    rows <- list(
      list(lazy_map(leaf, fn = function(v) v * 1000L + 1L), 65001001),
      list(lazy_map(leaf, fn = function(v) g_bitand(v, 1L)), 1)
    )
    for (row in rows) {
      expect_null(.gd_decompose(plan_lazy(row[[1L]])))
      got <- collect(row[[1L]], distributed = TRUE)
      expect_identical(garry_last_route(), "scheduler")
      .expect_cells(unclass(got), matrix(row[[2L]], 40L, 60L))
    }
    # a float leaf stays on the path, integer source or not
    mean_leaf <- lazy_map(reduce_over(stack, "median", "t"), fn = function(v) v + 1)
    expect_false(is.null(.gd_decompose(plan_lazy(mean_leaf))))
    got <- collect(mean_leaf, distributed = TRUE)
    expect_identical(garry_last_route(), "gd_reduce")
    .expect_cells(unclass(got), matrix(65002, 40L, 60L))
  })

  test_that("an upper stack on one row or one column keeps the grid's shape", {
    for (d in list(c(5L, 1L), c(1L, 5L))) {
      nx <- d[[1L]]
      ny <- d[[2L]]
      x <- .gg_narrow_stack(nx, ny)
      got <- collect(x, distributed = TRUE)
      expect_identical(garry_last_route(), "gd_reduce")
      want <- array(c(103 + 2 * seq_len(nx * ny), rep(100, nx * ny)), c(ny, nx, 2L))
      expect_identical(dim(got), dim(want), info = paste(d, collapse = " x "))
      .gg_identical(got, want)
      f <- withr::local_tempfile(fileext = ".tif")
      write_tif(x, f)
      expect_identical(garry_last_route(), "gd_reduce")
      expect_equal(gdal_read_window(f, 1L, 0L, 0L, nx, ny), array(want[, , 1L], c(ny, nx)), ignore_attr = TRUE)
      expect_equal(gdal_read_window(f, 2L, 0L, 0L, nx, ny), matrix(100, ny, nx), ignore_attr = TRUE)
    }
  })

  test_that("a focal on a composite runs warp-on-read == scheduler", {
    cs <- .gg_composites()
    # a 3 x 3 mean of a plane is its centre, and NaN where it leaves the raster
    want <- .gg_a
    want[c(1L, 40L), ] <- NaN
    want[, c(1L, 60L)] <- NaN
    .gg_equal(focal_map(cs$A, radius = 1L, fn = function(sh) Reduce(`+`, sh) / length(sh)), want)
  })
})
