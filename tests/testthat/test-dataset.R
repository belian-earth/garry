# LazyDataset: the named multi-band, multi-time object whose verbs apply across
# every band. These gates fix that dataset ops equal the hand-written per-band /
# per-slice primitive path (as_dataset + reduce_over + mask vs manual lazy_stack
# + lazy_map), that masking (value-set, qa_bits, morphology) matches a mask in
# plain R, that indexing/collect assemble the band axis, and that the distributed
# executor holds a masked composite's plain-R value.

# Two-slice, two-band dataset plus a QA band, all on one shared graph.
ds_fixture <- function(f) {
  g <- graph_new()
  src <- function() lazy_source(f, graph = g)
  as_dataset(
    list(
      V1 = list(s1 = src() * 1, s2 = src() * 2),
      V2 = list(s1 = src() * 3, s2 = src() * 4),
      Q  = list(s1 = src(),     s2 = src() + 1)
    ),
    mask_asset = "Q"
  )
}

# The median of two slices, NaN marking a slice a mask took.
.ds_median2 <- function(a, b) {
  ifelse(is.nan(a), b, ifelse(is.nan(b), a, (a + b) / 2))
}

# Grow a logical [y, x] mask by a disk of radius `r`.
.ds_dilate <- function(m, r) {
  disk <- expand.grid(dy = -r:r, dx = -r:r)
  disk <- disk[disk$dx^2 + disk$dy^2 <= r^2, ]
  ys <- seq_len(nrow(m))
  xs <- seq_len(ncol(m))
  out <- m
  for (i in seq_len(nrow(disk))) {
    y <- ys[(ys + disk$dy[[i]]) %in% ys]
    x <- xs[(xs + disk$dx[[i]]) %in% xs]
    out[y, x] <- out[y, x] | m[y + disk$dy[[i]], x + disk$dx[[i]]]
  }
  out
}
.ds_erode <- function(m, r) !.ds_dilate(!m, r)

# A value band over two slices with a QA band that flags, on a 44 x 36 grid,
# a block, a one-cell speck and a stripe 3 cells wide. An opening of radius 2
# takes the speck and the stripe and leaves the block. Every flag sits at least
# 8 cells from the edge, so the oracle has no raster border to model.
.ds_masked <- function() {
  gt <- c(0, 10, 0, 360, 0, -10)
  tile <- function(m) fixture_tile(t(m), gt = gt, nx = 44L, ny = 36L)
  flags <- function(rows, cols, speck, stripe) {
    m <- matrix(FALSE, 36L, 44L)
    m[rows, cols] <- TRUE
    m[speck[[1L]], speck[[2L]]] <- TRUE
    m[stripe, 12:30] <- TRUE
    m
  }
  q1 <- flags(12:20, 14:24, c(14L, 31L), 25:27)
  q2 <- flags(16:24, 20:32, c(11L, 12L), 12:14)
  v <- .fixture_values(44L, 36L)
  fv <- tile(v)
  fq1 <- tile(q1 * 1)
  fq2 <- tile(q2 * 2)
  g <- graph_new()
  src <- function(f) lazy_source(f, graph = g)
  ds <- as_dataset(
    list(V = list(s1 = src(fv), s2 = src(fv) * 2), Q = list(s1 = src(fq1), s2 = src(fq2))),
    mask_asset = "Q"
  )
  list(ds = ds, v = v, q1 = q1, q2 = q2)
}

# What apply_mask() then a median over t leave of it, with `clean` run on
# each slice's flags.
.ds_masked_want <- function(fx, clean) {
  s1 <- fx$v
  s1[clean(fx$q1)] <- NaN
  s2 <- fx$v * 2
  s2[clean(fx$q2)] <- NaN
  .ds_median2(s1, s2)
}

test_that("as_dataset builds a named dataset; indexing round-trips", {
  ds <- ds_fixture(fixture_gradient_f32())
  expect_true(S7::S7_inherits(ds, LazyDataset))
  expect_identical(names(ds@bands), c("V1", "V2", "Q"))
  expect_identical(ds@mask_asset, "Q")
  # [[ ]] on a multi-slice band -> a (t, y, x) LazyRaster; [ ] -> sub-dataset
  expect_true(S7::S7_inherits(ds[["V1"]], LazyRaster))
  sub <- ds[c("V1", "V2")]
  expect_true(S7::S7_inherits(sub, LazyDataset))
  expect_identical(names(sub@bands), c("V1", "V2"))
  expect_length(sub@mask_asset, 0L)   # Q not in the subset
})

test_that("reduce_over per band takes each band's median", {
  ds <- ds_fixture(fixture_gradient_f32())

  red <- reduce_over(ds, "median", "t")
  expect_true(all(vapply(red@bands, length, 1L) == 1L))  # one composite per band
  out <- collect(red)                                    # (y, x, band)
  expect_equal(dim(out), c(40L, 60L, 3L))
  # V1 is the fixture times 1 and 2
  expect_equal(out[, , 1], .fixture_values(60L, 40L) * 1.5, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("collect on a single-band dataset returns a matrix", {
  ds <- ds_fixture(fixture_gradient_f32())["V1"]
  out <- collect(reduce_over(ds, "mean", "t"))
  expect_equal(dim(out), c(40L, 60L))
})

test_that("apply_mask(value set) flags category membership", {
  ds <- ds_fixture(fixture_gradient_f32())
  # Q's slices are the fixture's values, then those values + 1
  vals <- c(101, 202, 303)
  got <- collect(reduce_over(apply_mask(ds, where = vals), "median", "t"))
  m <- .fixture_values(60L, 40L)
  s1 <- m
  s1[m %in% vals] <- NaN
  s2 <- m * 2
  s2[(m + 1) %in% vals] <- NaN
  expect_identical(c(sum(is.nan(s1)), sum(is.nan(s2))), c(3L, 2L)) # no cell holds 100
  .gg_close(got[, , 1], .ds_median2(s1, s2))
  .gg_close(got[, , 2], .ds_median2(s1 * 3, s2 * 2))
})

test_that("mask morphology (open + dilate) grows and cleans by a disk", {
  fx <- .ds_masked()
  got <- collect(reduce_over(apply_mask(fx$ds, where = qa_bits(0:1), open = 2, dilate = 3),
                             "median", "t"), distributed = FALSE)
  clean <- function(m) .ds_dilate(.ds_dilate(.ds_erode(m, 2L), 2L), 3L)
  .gg_close(got, .ds_masked_want(fx, clean))
  # the opening took what it should
  expect_false(clean(fx$q1)[14L, 31L])
  expect_false(clean(fx$q2)[11L, 12L])
  expect_false(any(clean(fx$q1)[26L, ]))
})

test_that("lazy_map over a dataset skips the mask band; bands= selects", {
  ds <- ds_fixture(fixture_gradient_f32())
  scaled <- lazy_map(ds, fn = function(v) v / 10, dtype = "f32")
  expect_identical(scaled@bands$Q, ds@bands$Q)           # QA untouched
  expect_false(identical(scaled@bands$V1, ds@bands$V1))  # value band changed

  one <- lazy_map(ds, fn = function(v) v / 10, dtype = "f32", bands = "V1")
  expect_false(identical(one@bands$V1, ds@bands$V1))
  expect_identical(one@bands$V2, ds@bands$V2)             # V2 not selected
})

test_that("stack_bands needs one layer per band", {
  ds <- ds_fixture(fixture_gradient_f32())
  expect_error(stack_bands(ds), "one layer per band")
  expect_silent(stack_bands(reduce_over(ds["V1"], "mean", "t")))
})

test_that("scalar arithmetic scales value bands and leaves the mask band", {
  ds <- ds_fixture(fixture_gradient_f32())
  scaled <- ds * 0.1
  expect_identical(scaled@bands$Q, ds@bands$Q)           # QA untouched
  got <- collect(reduce_over(scaled["V1"], "mean", "t"))
  expect_equal(got, .fixture_values(60L, 40L) * 0.15, tolerance = 1e-6, ignore_attr = TRUE)
  expect_true(S7::S7_inherits(100 - ds, LazyDataset))    # scalar-first
})

test_that("dataset + dataset combines shared value bands slice by slice", {
  f <- fixture_gradient_f32()
  a <- ds_fixture(f)                                      # V1, V2, Q
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  b <- as_dataset(list(V1 = list(s() * 10, s() * 20)))

  summed <- a["V1"] + b
  expect_identical(names(summed@bands), "V1")
  expect_length(summed@mask_asset, 0L)
  got <- collect(reduce_over(summed, "mean", "t"))
  expect_equal(got, .fixture_values(60L, 40L) * 16.5, tolerance = 1e-6, ignore_attr = TRUE)
})

# Fabricate a doc_items-shaped list with a value asset (V) and a QA asset (Q)
# over local tiles, so lazy_dataset()'s STAC path (per-asset GTI index + grid
# probe + slice mosaics) runs fully offline. Q holds small integer flags that
# vary per slice so masking differs across time.
.ds_fake_items <- function() {
  dates <- c("2023-01-05T01:00:00Z", "2023-01-15T01:00:00Z", "2023-02-05T01:00:00Z")
  mk <- function(nm, m) {
    f <- file.path(tempdir(), nm)
    ds <- gdalraster::create("GTiff", f, 20, 16, 1, "Float32", return_obj = TRUE)
    ds$setGeoTransform(c(0, 10, 0, 160, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    ds$write(1, 0, 0, 20, 16, as.numeric(t(m)))
    ds$close()
    f
  }
  b <- gdalraster::transform_bounds(c(0, 0, 200, 160), "EPSG:3857", "EPSG:4326")
  feats <- lapply(1:3, function(i) {
    V <- outer(1:16, 1:20, function(r, c2) r * 100 + c2) + (i - 1) * 1000
    Q <- matrix((seq_len(16 * 20) + i) %% 5, 16, 20)   # flags 0..4, vary by slice
    list(id = sprintf("item-%d", i), bbox = as.list(b),
         properties = list(datetime = dates[[i]], `eo:cloud_cover` = 10),
         assets = list(V = list(href = mk(sprintf("garry-ds-V%d.tif", i), V)),
                       Q = list(href = mk(sprintf("garry-ds-Q%d.tif", i), Q))))
  })
  list(features = feats)
}

test_that("lazy_dataset builds from a STAC table and masks end to end (offline)", {
  src  <- stac_sources(.ds_fake_items(), assets = c("V", "Q"))
  vloc <- src$location[src$asset == "V"]
  qloc <- src$location[src$asset == "Q"]
  grid <- gdal_grid_spec(vloc[[1]])$grid                 # native 3857 grid

  ds <- lazy_dataset(src, grid, assets = "V", mask_asset = "Q")
  expect_identical(names(ds@bands), c("V", "Q"))
  expect_identical(ds@mask_asset, "Q")
  expect_length(ds@bands$V, 3L)                          # three day slices
  expect_named(ds@bands$V, c("2023-01-05", "2023-01-15", "2023-02-05"))

  masked <- apply_mask(ds, where = qa_bits(0:1))
  expect_false("Q" %in% names(masked@bands))             # QA dropped
  got <- collect(reduce_over(masked, "median", "t"))

  # plain-R reference: bad = (int(Q) & 3) > 0 -> NaN, then median over slices
  rd <- function(f) gdal_read_window(f, 1L, 0L, 0L, 20L, 16L)
  slabs <- lapply(1:3, function(i) {
    v <- rd(vloc[[i]]); q <- rd(qloc[[i]])
    v[bitwAnd(as.integer(q), 3L) > 0] <- NaN
    v
  })
  arr  <- g_stack(slabs)
  want <- apply(arr, c(2, 3), function(v) { m <- median(v, na.rm = TRUE); if (is.na(m)) NaN else m })
  expect_identical(is.nan(got), is.nan(want))
  ok <- !is.nan(want)
  expect_equal(got[ok], want[ok], tolerance = 1e-5)
})

test_that("lazy_dataset threads resampling to value bands, keeps the mask near", {
  src  <- stac_sources(.ds_fake_items(), assets = c("V", "Q"))
  grid <- gdal_grid_spec(src$location[src$asset == "V"][[1]])$grid
  rs_of <- function(ds, b) unique(vapply(ds@bands[[b]], function(lr)
    graph_get(lr@graph, lr@node_id)@resampling, ""))

  ds <- lazy_dataset(src, grid, assets = "V", mask_asset = "Q",
                     resampling = "average")
  expect_identical(rs_of(ds, "V"), "average")   # value band interpolates
  expect_identical(rs_of(ds, "Q"), "near")      # QA mask forced nearest

  # named per-asset form; a default of near for anything unnamed
  ds2 <- lazy_dataset(src, grid, assets = "V", mask_asset = "Q",
                      resampling = c(V = "bilinear"))
  expect_identical(rs_of(ds2, "V"), "bilinear")
  expect_identical(rs_of(ds2, "Q"), "near")

  # default is near, and an unknown method is rejected
  expect_identical(rs_of(lazy_dataset(src, grid, assets = "V"), "V"), "near")
  expect_error(lazy_dataset(src, grid, assets = "V", resampling = "bogus"),
               "Invalid")
})

test_that("a named per-band argument must name a band or asset", {
  src  <- stac_sources(.ds_fake_items(), assets = c("V", "Q"))
  grid <- gdal_grid_spec(src$location[src$asset == "V"][[1]])$grid
  typo <- function(...) {
    expect_error(lazy_dataset(src, grid, assets = "V", ...),
                 class = "garry_source_error")
  }
  typo(nodata = c(V_typo = 10))
  typo(scale = c(V_typo = 0.5))
  typo(scale = 0.5, offset = c(V_typo = 1))
  typo(resampling = c(V_typo = "bilinear"))
  expect_error(lazy_dataset(src, grid, assets = "V", nodata = c(V_typo = 10)),
               "V_typo")
  # an asset of the source this call leaves out is no typo
  ds <- lazy_dataset(src, grid, assets = "V", nodata = c(V = 10, Q = 0))
  v <- ds@bands$V[[1]]
  expect_identical(graph_get(v@graph, v@node_id)@nodata, 10)
})

test_that("several values need names to reach their bands", {
  f <- system.file("extdata", "garry-example.tif", package = "garry")
  src  <- stac_sources(.ds_fake_items(), assets = c("V", "Q"))
  grid <- gdal_grid_spec(src$location[src$asset == "V"][[1]])$grid
  for (make in list(
    function(...) lazy_dataset(f, ...),
    function(...) lazy_dataset(src, grid, assets = c("V", "Q"), ...)
  )) {
    expect_error(make(scale = c(0.1, 0.2)), class = "garry_source_error")
    expect_error(make(scale = 0.1, offset = c(1, 2)), class = "garry_source_error")
    expect_error(make(resampling = c("near", "bilinear")), class = "garry_source_error")
    expect_error(make(nodata = c(1, 2)), class = "garry_source_error")
    expect_error(make(scale = c(0.1, nope = 0.2)), class = "garry_source_error")
    expect_error(make(nodata = c(a = 1, a = 2)), class = "garry_source_error")
  }
})

test_that("resampling actually rescales the warp-on-read (near vs average)", {
  dir <- withr::local_tempdir("dsrs")
  s <- file.path(dir, "g.tif")
  d <- gdalraster::create("GTiff", s, 16, 16, 1, "Float32", return_obj = TRUE)
  d$setGeoTransform(c(0, 10, 0, 160, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  V <- outer(1:16, 1:16, function(r, c2) r * 100 + c2)     # smooth gradient
  d$write(1, 0, 0, 16, 16, as.numeric(t(V))); d$close()
  idx <- file.path(dir, "i.gti.fgb")
  gti_index_create(data.frame(location = s, datetime = "2023-01-01T00:00:00Z",
                              slice = "2023-01-01", cloud_cover = 0,
                              xmin = 0, ymin = 0, xmax = 160, ymax = 160),
                   idx, crs = "EPSG:3857")
  coarse <- grid_spec("EPSG:3857", extent = c(0, 0, 160, 160),
                      dims = c(8L, 8L), dtype = "f32")       # 2x coarser
  meta <- gdal_grid_spec(paste0("GTI:", idx),
                         open_options = gti_open_options(coarse))
  rd <- function(rs) collect(lazy_source(
    paste0("GTI:", idx), grid = meta$grid,
    open_options = gti_open_options(coarse, filter = "slice = '2023-01-01'",
                                    sort_field = "datetime"),
    resampling = rs), distributed = FALSE)

  near <- rd("near"); avg <- rd("average")
  expect_false(isTRUE(all.equal(unname(near), unname(avg))))  # resampling applied
  # the top-left coarse cell covers source pixels {101,102,201,202}: mean 151.5
  expect_equal(unname(avg[1, 1]), 151.5, tolerance = 1e-4)
  expect_true(unname(near[1, 1]) %in% c(101, 102, 201, 202))  # near picks a sample
})

test_that("a derived band joins the graph and is written by collect", {
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  comp <- as_dataset(list(B04 = list(s() * 1), B03 = list(s() * 2),
                          B02 = list(s() * 3)))

  comp[["ratio"]] <- comp[["B03"]] * comp[["B02"]]
  expect_identical(names(comp@bands), c("B04", "B03", "B02", "ratio"))

  out <- collect(comp)                          # (y, x, band)
  expect_equal(dim(out), c(40L, 60L, 4L))       # the derived band is written
  b03 <- collect(comp[["B03"]]); b02 <- collect(comp[["B02"]])
  expect_equal(out[, , 4], b03 * b02, tolerance = 1e-4, ignore_attr = "gis")

  # an index-style band from arithmetic + scalars also composes
  comp[["ndvi"]] <- (comp[["B04"]] - comp[["B03"]]) /
    (comp[["B04"]] + comp[["B03"]])
  expect_equal(dim(collect(comp)), c(40L, 60L, 5L))
})

test_that("assigning a band on the wrong grid is rejected", {
  f <- fixture_gradient_f32()
  g <- graph_new()
  comp <- as_dataset(list(B04 = list(lazy_source(f, graph = g))))
  other <- lazy_source(fixture_i16_nodata())    # different grid
  expect_error({ comp[["bad"]] <- other }, "grid")
  expect_error({ comp[["x"]] <- 42 }, "LazyRaster")
})

test_that("collect writes dataset band names as GDAL descriptions", {
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  ds <- as_dataset(list(red = list(s()), green = list(s() * 2), blue = list(s() * 3)))
  ds[["ndvi"]] <- ds[["red"]] / ds[["green"]]
  out <- tempfile(fileext = ".tif")
  write_tif(ds, out, nodata = -9999, distributed = FALSE)
  r <- new(gdalraster::GDALRaster, out); on.exit(r$close())
  expect_equal(vapply(1:4, function(b) r$getDescription(b), character(1)),
               c("red", "green", "blue", "ndvi"))
})

local({
  local_pools(2, 1)

  test_that("distributed collect writes band descriptions too", {
    f <- fixture_gradient_f32()
    g <- graph_new(); s <- function() lazy_source(f, graph = g)
    ds <- as_dataset(list(a = list(s(), s() * 2), b = list(s() * 3, s() * 4)))
    comp <- reduce_over(ds, "median", "t")     # plain sources -> scheduler path
    out <- tempfile(fileext = ".tif")
    write_tif(comp, out, distributed = TRUE)
    r <- new(gdalraster::GDALRaster, out); on.exit(r$close(), add = TRUE)
    expect_equal(vapply(1:2, function(b) r$getDescription(b), character(1)),
                 c("a", "b"))
  })

  test_that("distributed masked composite equals the oracle", {
    fx <- .ds_masked()
    x <- reduce_over(apply_mask(fx$ds, where = qa_bits(0:1), dilate = 2), "median", "t")
    .local_px(400, x)                          # halos across spatial chunks
    want <- .ds_masked_want(fx, function(m) .ds_dilate(m, 2L))
    .gg_close(collect(x, distributed = TRUE), want)
    expect_identical(garry_last_route(), "scheduler")
    .gg_close(collect(x, distributed = FALSE), want)
  })
})

test_that("assigning band math to a multi-slice dataset keeps per-slice layers", {
  f <- fixture_gradient_f32()
  ds <- ds_fixture(f)
  ds$r <- (ds$V1 - ds$V2) / (ds$V1 + ds$V2)
  expect_identical(names(ds@bands$r), c("s1", "s2"))
  expect_identical(dim(ds$r), dim(ds$V1))
  comp <- reduce_over(ds, "mean", "t", bands = "r")
  want <- mean(c((1 - 3) / (1 + 3), (2 - 4) / (2 + 4)))
  expect_equal(unique(as.vector(collect(comp$r))), want, tolerance = 1e-6)
  # the other per-slice verbs accept it too
  expect_no_error(apply_mask(ds, where = qa_bits(0:1)))
  # a t axis with no per-slice form is refused, not stored as one layer
  expect_error(
    ds$bad <- focal_map(ds$V1, fn = function(sh) Reduce(`+`, sh), radius = 1L),
    "cannot be split"
  )
})

test_that("dataset verbs check band names and keep the mask out of band reductions", {
  ds <- ds_fixture(fixture_gradient_f32())
  expect_error(lazy_map(ds, fn = function(v) v, bands = "typo"), "must name bands")
  expect_error(ds["typo"], "must name bands")
  expect_error(reduce_over(ds, "mean", "t", bands = "typo"), "must name bands")
  red <- reduce_over(reduce_over(ds, "mean", "t"), "mean", "band")
  v1 <- collect(reduce_over(ds, "mean", "t")$V1)
  v2 <- collect(reduce_over(ds, "mean", "t")$V2)
  expect_equal(collect(red), (v1 + v2) / 2, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("qa_bits builds the mask from distinct bits", {
  f <- function(b) qa_bits(b)(matrix(c(2, 4, 6), 1, 3))
  expect_identical(f(c(1, 1)), f(1))
  expect_identical(as.vector(f(1)), c(1, 0, 1))
  expect_error(qa_bits(31), "0..30")
})

test_that("fill_gaps leaves single-slice bands alone", {
  f <- fixture_gradient_f32()
  g <- graph_new()
  s <- function(k) lazy_source(f, graph = g) * k
  ds <- as_dataset(list(a = list(t1 = s(1), t2 = s(2)), b = list(t1 = s(3))))
  out <- fill_gaps(ds, "ffill")
  expect_identical(collect(out$b), collect(ds$b))
})

test_that("as_dataset and lazy_map refuse non-raster input clearly", {
  f <- fixture_gradient_f32()
  expect_error(as_dataset(list(a = 5)), "must hold")
  expect_error(lazy_map(5, fn = identity), "LazyRaster")
  other <- lazy_source(fixture_3857_f64())
  expect_error(as_dataset(list(a = lazy_source(f), b = other)), "not on the first band's grid")
})

test_that("a tile index masks its tiles' own sentinel and will not warp past it", {
  b <- gdalraster::transform_bounds(c(0, 0, 40, 40), "EPSG:3857", "EPSG:4326")
  items <- list(features = list(list(
    id = "a", bbox = as.list(b),
    properties = list(datetime = "2023-01-05T01:00:00Z", `eo:cloud_cover` = 10),
    assets = list(V = list(href = fixture_tile(c(0, 5, 7, 7), nodata = 0)))
  )))
  src <- stac_sources(items, assets = "V")
  g <- grid_spec("EPSG:3857", extent = c(0, 0, 40, 40), dims = c(4L, 4L), dtype = "f32")
  ds <- lazy_dataset(src, g, assets = "V", nodata = 5)
  m <- collect(ds, distributed = FALSE)
  expect_true(all(is.nan(m[, 1:2])) && all(m[, 3:4] == 7))
  half <- grid_spec("EPSG:3857", extent = c(0, 0, 40, 40), dims = c(2L, 2L))
  expect_error(collect(align_to(ds@bands$V[[1L]], half), distributed = FALSE),
               class = "garry_source_error")
  # the sentinel they declare warps as ever
  same <- lazy_dataset(src, g, assets = "V", nodata = 0)
  w <- collect(align_to(same@bands$V[[1L]], half), distributed = FALSE)
  expect_identical(dim(w), c(2L, 2L))
})

test_that("dataset arithmetic refuses value bands only one side has", {
  f <- fixture_gradient_f32()
  a <- ds_fixture(f)
  g <- graph_new()
  b <- as_dataset(list(V1 = list(s1 = lazy_source(f, graph = g), s2 = lazy_source(f, graph = g))))
  err <- expect_error(a + b, class = "garry_source_error")
  expect_match(conditionMessage(err), "V2", fixed = TRUE)
  expect_no_error(a["V1"] + b) # select what the two share
})

test_that("apply_mask takes whole radii and names the argument", {
  ds <- lazy_dataset(system.file("extdata", "garry-example.tif", package = "garry"))
  expect_error(apply_mask(ds, from = "qa", where = 2, open = 1.5), "open")
  expect_error(apply_mask(ds, from = "qa", where = 2, dilate = -1), "dilate")
})

test_that("the file form refuses what it would ignore", {
  f <- system.file("extdata", "garry-example.tif", package = "garry")
  expect_error(lazy_dataset(f, granularity = "month"), "granularity", fixed = TRUE)
  expect_error(lazy_dataset(f, bands = c(1, 1)), "each once", fixed = TRUE)
  expect_error(lazy_dataset(f, bands = 1.7), "whole position", fixed = TRUE)
  expect_error(lazy_source(f, band = 1.7), "one whole band number", fixed = TRUE)
  # a read takes one band, so a vector would fail only there
  expect_error(lazy_source(f, band = 1:2), "one whole band number", fixed = TRUE)
  nms <- names(lazy_dataset(f))
  expect_error(lazy_dataset(f, mask_asset = nms[1:2]), "one selected band", fixed = TRUE)
})

test_that("stac_time_slices refuses a longitude only solar_day reads", {
  tbl <- data.frame(datetime = "2023-06-01T00:00:00Z", xmin = 0, xmax = 1)
  expect_error(stac_time_slices(tbl, "day", lon = 170), "solar_day", fixed = TRUE)
})
