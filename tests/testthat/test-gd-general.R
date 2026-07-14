# General warp-on-read executor (.gd_spec / .execute_gd_general): the single
# path for any warp-on-read-eligible plan. It warps every GTI source and
# compiles the WHOLE reachable IR into one jit, so derived bands, band math,
# focal, and nested reduce -> map -> reduce all run fused -- and byte-identically
# to the general scheduler (execute_plan_mirai), for any shape .cd_spec (the
# composite fast path) does not match.

skip_if_not_installed("anvl")
skip_if_not_installed("mirai")

.gg_grid <- grid_spec("EPSG:3857", extent = c(0, 0, 600, 400),
                      dims = c(60L, 40L), dtype = "f32")

# A local, sliced GTI over per-slice tiles (with the .meta.rds sidecar the
# warp-on-read path reads), so it is exercisable offline.
.gg_gti <- function(slices) {
  ent <- do.call(rbind, lapply(names(slices), function(sl) {
    f <- tempfile(fileext = ".tif")
    d <- gdalraster::create("GTiff", f, 60, 40, 1, "Float32", return_obj = TRUE)
    d$setGeoTransform(c(0, 10, 0, 400, 0, -10))
    d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    d$write(1, 0, 0, 60, 40, as.numeric(t(slices[[sl]]))); d$close()
    data.frame(location = f, slice = sl, datetime = sl,
               xmin = 0, ymin = 0, xmax = 600, ymax = 400)
  }))
  gti <- tempfile(fileext = ".gti.fgb")
  gti_index_create(ent, gti, crs = "EPSG:3857")
  gti
}

.gg_slice <- function(gti, s, graph) lazy_source(
  paste0("GTI:", gti), graph = graph,
  open_options = gti_open_options(.gg_grid, filter = sprintf("slice = '%s'", s),
                                  sort_field = "datetime"),
  grid = .gg_grid, block_dim = c(60L, 40L))

.gg_val <- function(base) outer(1:40, 1:60, function(r, c) r + c) + base

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

# Strict comparator: identical NaN pattern AND exact (tolerance 0) values on the
# finite cells -- the row-block pipeline must be byte-identical to the whole-grid
# kernel, not merely close.
.gg_identical <- function(a, b) {
  a <- if (is.list(a)) a else list(a)
  b <- if (is.list(b)) b else list(b)
  expect_equal(length(a), length(b))
  for (i in seq_along(a)) {
    av <- as.numeric(a[[i]]); bv <- as.numeric(b[[i]])
    expect_identical(is.nan(av), is.nan(bv))
    expect_equal(av[!is.nan(av)], bv[!is.nan(bv)], tolerance = 0)
  }
}

.gg_equal <- function(x) {
  p <- plan_lazy(x)
  gsp <- .gd_spec(p)
  expect_false(is.null(gsp))                          # takes the general path
  expect_true(is.null(.cd_spec(p)))                   # NOT the composite fast path
  gen   <- .execute_gd_general(p, gsp)
  sched <- execute_plan_mirai(p)
  ok <- !is.nan(as.numeric(sched))
  expect_equal(as.numeric(gen)[ok], as.numeric(sched)[ok], tolerance = 1e-5)
  # Reduce-decomposition (the general path): compute the leaf temporal reduces
  # via the overlapped per-band pipeline, then run the upper IR on the 2D results
  # -- byte-identical to the whole-grid kernel.
  dc <- .gd_decompose(p)
  expect_false(is.null(dc))
  .gg_identical(.execute_gd_reduce(p, dc), gen)
}

test_that("a derived band (map over reduces) runs warp-on-read == scheduler", {
  garry_daemons(2, 2, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  cs <- .gg_composites()
  .gg_equal((cs$A - cs$B) / (cs$A + cs$B))            # ndvi shape
})

test_that("nested reduce -> map -> reduce runs warp-on-read == scheduler", {
  garry_daemons(2, 2, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  cs <- .gg_composites()
  ndvi <- (cs$A - cs$B) / (cs$A + cs$B)
  # a second derived band, then reduce over the band axis of the two
  top <- reduce_over(lazy_stack(list(ndvi, cs$A * 2 - cs$B), along = "band"),
                     "sum", "band")
  .gg_equal(top)
})

test_that("a focal on a composite runs warp-on-read == scheduler", {
  garry_daemons(2, 2, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  cs <- .gg_composites()
  .gg_equal(focal(cs$A, radius = 1L, fn = function(sh) Reduce(`+`, sh) / length(sh)))
})

test_that("collect() routes a derived band through the general path", {
  garry_daemons(2, 2, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  cs <- .gg_composites()
  ndvi <- (cs$A - cs$B) / (cs$A + cs$B)
  got  <- collect(ndvi, distributed = TRUE)
  want <- collect(ndvi, distributed = FALSE)
  ok <- !is.nan(as.numeric(want))
  expect_equal(as.numeric(got)[ok], as.numeric(want)[ok], tolerance = 1e-5)
})
