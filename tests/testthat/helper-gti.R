# Local, sliced GTI fixtures (with the .meta.rds sidecar the warp-on-read
# path reads), shared by the gd-general / composite-direct / route-matrix
# equivalence gates. Fully offline.

.gg_grid <- grid_spec("EPSG:3857", extent = c(0, 0, 600, 400),
                      dims = c(60L, 40L), dtype = "f32")

# A local, sliced GTI over per-slice tiles of GDAL type `type`.
.gg_gti <- function(slices, type = "Float32") {
  ent <- do.call(rbind, lapply(names(slices), function(sl) {
    f <- tempfile(fileext = ".tif")
    d <- gdalraster::create("GTiff", f, 60, 40, 1, type, return_obj = TRUE)
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

.gg_slice <- function(gti, s, graph, dtype = "f32") lazy_source(
  paste0("GTI:", gti), graph = graph,
  open_options = gti_open_options(.gg_grid, filter = sprintf("slice = '%s'", s),
                                  sort_field = "datetime"),
  grid = garry:::.grid_retype(.gg_grid, dtype), block_dim = c(60L, 40L))

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
.gg_masked_composite <- function(open = 0L, dilate = 0L, single = FALSE,
                                 type = "Float32", dtype = "f32", overlap = FALSE) {
  reduce_over(.gg_masked_dataset(open, dilate, single, type, dtype, overlap),
              "median", "t", nan_rm = TRUE)
}

# The two-band, two-date dataset of .gg_masked_composite(), masked and cleaned.
.gg_masked_dataset <- function(open = 0L, dilate = 0L, single = FALSE,
                               type = "Float32", dtype = "f32", overlap = FALSE) {
  gA <- .gg_gti(list(s1 = .gg_val(0),   s2 = .gg_val(10)), type)
  gB <- .gg_gti(list(s1 = .gg_val(100), s2 = .gg_val(50)), type)
  qa1 <- matrix(0, 40, 60); qa1[10:20, 10:30] <- 2
  q2 <- .gg_q2(overlap)
  qa2 <- matrix(0, 40, 60); qa2[q2$rows, q2$cols] <- 2
  gQ <- .gg_gti(list(s1 = qa1, s2 = qa2), type)
  g <- graph_new()
  sl <- function(gti) list(s1 = .gg_slice(gti, "s1", g, dtype),
                           s2 = .gg_slice(gti, "s2", g, dtype))
  vars <- list(V1 = sl(gA), V2 = sl(gB), Q = sl(gQ))
  if (single) vars$V2 <- NULL
  ds <- as_dataset(vars, mask_asset = "Q")
  apply_mask(ds, where = c(2), open = open, dilate = dilate)
}

# Six dates of two bands, whose medians are .gg_val(35) and .gg_val(135), under
# a mask that shares a node with something else. "static" is one QA plane read
# for every date, as a land-cover or DEM threshold is. "self" masks by the first
# band's own source.
.gg_dated_dataset <- function(mask, open = 0L, dilate = 0L) {
  dates <- paste0("s", 1:6)
  planes <- function(base) stats::setNames(lapply(1:6, function(i) .gg_val(base + 10 * i)), dates)
  g <- graph_new()
  sl <- function(gti) stats::setNames(lapply(dates, function(d) .gg_slice(gti, d, g)), dates)
  A <- sl(.gg_gti(planes(0)))
  B <- sl(.gg_gti(planes(100)))
  if (identical(mask, "static")) {
    S <- .gg_slice(.gg_gti(list(st = .gg_static_qa())), "st", g)
    ds <- as_dataset(list(V1 = A, V2 = B, Q = stats::setNames(rep(list(S), 6L), dates)), mask_asset = "Q")
    return(apply_mask(ds, where = c(2), open = open, dilate = dilate))
  }
  ds <- as_dataset(list(V1 = A, V2 = B, Q = A), mask_asset = "Q")
  apply_mask(ds, where = function(q) g_cast(q > 60, "f32"), open = open, dilate = dilate)
}

.gg_static_qa <- function() {
  qa <- matrix(0, 40, 60)
  qa[10:20, 10:30] <- 2
  qa
}

# The same two bands as a bare (band, t, y, x) cube.
.gg_unmasked_cube <- function() {
  gA <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
  gB <- .gg_gti(list(s1 = .gg_val(100), s2 = .gg_val(50)))
  g <- graph_new()
  band <- function(gti) lazy_stack(list(s1 = .gg_slice(gti, "s1", g), s2 = .gg_slice(gti, "s2", g)), along = "t")
  lazy_stack(list(V1 = band(gA), V2 = band(gB)), along = "band")
}

# What the second slice masks. With `overlap` some cells are masked in both
# slices, which no slice then holds; otherwise every cell has a value.
.gg_q2 <- function(overlap) {
  if (overlap) list(rows = 15:25, cols = 20:40) else list(rows = 25:35, cols = 40:55)
}

# What .gg_masked_composite() holds, from plain R: each band's median over
# the slices its mask leaves, NaN where none does. `clean` is open = 1L,
# dilate = 1L, whose disk of radius 1 is a cross; the masks stay clear of the
# raster's edge.
.gg_masked_want <- function(clean = FALSE, single = FALSE, overlap = FALSE) {
  grow <- function(m) {
    m | rbind(m[-1L, ], FALSE) | rbind(FALSE, m[-nrow(m), ]) |
      cbind(m[, -1L], FALSE) | cbind(FALSE, m[, -ncol(m)])
  }
  mask <- function(rows, cols) {
    m <- matrix(FALSE, 40L, 60L)
    m[rows, cols] <- TRUE
    if (clean) grow(grow(!grow(!m))) else m
  }
  q1 <- mask(10:20, 10:30)
  q2 <- do.call(mask, .gg_q2(overlap))
  band <- function(base1, base2) {
    a <- .gg_val(base1); a[q1] <- NaN
    b <- .gg_val(base2); b[q2] <- NaN
    ifelse(is.nan(a), b, ifelse(is.nan(b), a, (a + b) / 2))
  }
  if (single) band(0, 10) else array(c(band(0, 10), band(100, 50)), c(40L, 60L, 2L))
}
