# Local, sliced GTI fixtures (with the .meta.rds sidecar the warp-on-read
# path reads), shared by the gd-general / composite-direct / route-matrix
# equivalence gates. Fully offline.

.gg_grid <- grid_spec("EPSG:3857", extent = c(0, 0, 600, 400),
                      dims = c(60L, 40L), dtype = "f32")

# A local, sliced GTI over per-slice tiles.
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

# Strict comparator: identical NaN pattern AND exact (tolerance 0) values on the
# finite cells.
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

# As .gg_identical but with a tolerance on the finite cells (routes whose
# compute is structurally different — chunked scheduler vs whole-grid
# kernel — agree to f32 noise, not bytes).
.gg_close <- function(a, b, tolerance = 1e-6) {
  av <- as.numeric(a); bv <- as.numeric(b)
  expect_identical(is.nan(av), is.nan(bv))
  expect_equal(av[!is.nan(av)], bv[!is.nan(bv)], tolerance = tolerance)
}

# A masked (optionally morphology-cleaned) two-band + QA composite over
# local GTIs: the canonical .cd_spec shape (band/mask MapNodes per slice,
# shared mask chain, temporal median), built through the public dataset
# verbs exactly as the HLS benchmark builds it.
.gg_masked_composite <- function(open = 0L, dilate = 0L) {
  gA <- .gg_gti(list(s1 = .gg_val(0),   s2 = .gg_val(10)))
  gB <- .gg_gti(list(s1 = .gg_val(100), s2 = .gg_val(50)))
  qa1 <- matrix(0, 40, 60); qa1[10:20, 10:30] <- 2
  qa2 <- matrix(0, 40, 60); qa2[25:35, 40:55] <- 2
  gQ <- .gg_gti(list(s1 = qa1, s2 = qa2))
  g <- graph_new()
  ds <- as_dataset(list(
    V1 = list(s1 = .gg_slice(gA, "s1", g), s2 = .gg_slice(gA, "s2", g)),
    V2 = list(s1 = .gg_slice(gB, "s1", g), s2 = .gg_slice(gB, "s2", g)),
    Q  = list(s1 = .gg_slice(gQ, "s1", g), s2 = .gg_slice(gQ, "s2", g))
  ), mask_asset = "Q")
  reduce_over(mask(ds, where = c(2), open = open, dilate = dilate),
              "median", "t", nan_rm = TRUE)
}
