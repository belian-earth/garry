# Pipeline tail levers: strip-decomposed band medians are byte-identical
# to whole-band jobs and match the single-process oracle; the
# content-addressed kernel cache + fetch-window warm mean a repeat
# collect compiles nothing new; g_fill builds device constants.


skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")

test_that(".gd_strip_bounds tiles exactly with at most two heights", {
  for (ny in c(1L, 7L, 40L, 1480L)) {
    for (ns in c(1L, 2L, 3L, 6L, 64L)) {
      b <- garry:::.gd_strip_bounds(ny, ns)
      starts <- vapply(b, `[[`, integer(1), 1L)
      heights <- vapply(b, `[[`, integer(1), 2L)
      expect_identical(starts[[1L]], 0L)
      expect_identical(starts[-1L], (starts + heights)[-length(b)])  # contiguous
      expect_identical(sum(heights), ny)                             # covers
      expect_true(all(heights >= 1L))
      expect_lte(length(unique(heights)), 2L)                        # <=2 shapes
      expect_lte(length(b), max(1L, min(ns, ny)))
    }
  }
})

test_that("g_fill builds a device constant equal to the R fill", {
  skip_if(!rlang::is_installed("anvl"), "anvl not installed")
  a <- g_fill(1.5, c(2L, 3L))
  expect_equal(g_download(a), matrix(1.5, 2, 3), ignore_attr = TRUE)
})

test_that("strip-decomposed pipeline equals whole-band jobs and the oracle", {
  local_pools(2, 2)
  x <- .gg_masked_composite(open = 1L, dilate = 1L)
  want <- collect(x, distributed = FALSE)
  res <- lapply(c(1L, 3L), function(ns) {
    old2 <- options(garry.gd_strips = ns)
    on.exit(options(old2), add = TRUE)
    got <- collect(x, distributed = TRUE)
    expect_identical(garry_last_route(), "composite_direct")
    got
  })
  expect_identical(res[[1L]], res[[2L]])   # strips reassemble byte-identically
  .gg_close(res[[2L]], want)
})

test_that("repeat collect creates no new pipeline kernels (cache + warm)", {
  skip_on_os("mac")   # daemons start every run cold there (.daemon_jit_reset)
  local_pools(2, 2)
  old <- options(garry.gd_strips = 2)
  on.exit(options(old), add = TRUE)
  x <- .gg_masked_composite()
  creates <- function() sum(vapply(garry:::.comp_profiles(), function(p)
    mirai::mirai(asNamespace("garry")$.daemon_jit_creates(), .compute = p)[], integer(1)))
  invisible(collect(x, distributed = TRUE))
  c1 <- creates()
  expect_gte(c1, 1L)                       # warm or first use compiled something
  invisible(collect(x, distributed = TRUE))
  expect_identical(creates(), c1)          # second run: every kernel cache-hits
})

# One band's temporal median of `band x mask`, its fn parsed afresh with a
# source reference: the same kernel to anvl, different bytes to serialize().
.gt_masked_band <- function(gti, q, g) {
  f <- eval(parse(text = "function(x, m) x * m", keep.source = TRUE))
  reduce_over(lazy_stack(Map(function(s, m) {
    lazy_map(.gg_slice(gti, s, g), m, fn = f)
  }, c("s1", "s2"), q)), "median", "t")
}

.gt_two_bands <- function(spare = 0L) {
  gA <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
  gB <- .gg_gti(list(s1 = .gg_val(100), s2 = .gg_val(50)))
  gQ <- .gg_gti(list(s1 = .gg_val(1), s2 = .gg_val(2)))
  g <- graph_new()
  # spare nodes move every later node id
  for (i in seq_len(spare)) {
    lazy_source(fixture_gradient_f32(), graph = g)
  }
  q <- lapply(c("s1", "s2"), function(s) .gg_slice(gQ, s, g))
  list(A = .gt_masked_band(gA, q, g), B = .gt_masked_band(gB, q, g))
}

test_that("fns differing only in their source reference share a kernel", {
  skip_on_os("mac")
  local_pools(2, 2)
  old <- options(garry.gd_strips = 1)
  on.exit(options(old), add = TRUE)
  creates <- function() sum(vapply(garry:::.comp_profiles(), function(p)
    mirai::mirai(asNamespace("garry")$.daemon_jit_creates(), .compute = p)[], integer(1)))
  bands <- function() {
    b <- .gt_two_bands()
    lazy_stack(list(b$A, b$B), along = "band")
  }
  invisible(collect(bands(), distributed = TRUE))
  expect_identical(garry_last_route(), "composite_direct")
  c1 <- creates()
  invisible(collect(bands(), distributed = TRUE))
  expect_identical(creates(), c1)
})

test_that("leaf reduces with the same mask form one group", {
  b <- .gt_two_bands()
  dc <- garry:::.gd_decompose(plan_lazy((b$A - b$B) / (b$A + b$B)))
  expect_length(dc$groups, 1L)
  expect_identical(dc$groups[[1L]]$spec$n_bands, 2L)
})

test_that("a rebuilt plan reuses the gd routes' host kernels", {
  skip_on_os("mac")
  local_pools(2, 2)
  ndvi <- function(spare) {
    b <- .gt_two_bands(spare)
    (b$A - b$B) / (b$A + b$B)
  }
  garry:::.exec_jit_clear() # earlier tests hold these kernels too
  before <- garry:::.daemon_jit_creates()
  got <- collect(ndvi(0L), distributed = TRUE)
  expect_identical(garry_last_route(), "gd_reduce")
  n <- garry:::.daemon_jit_creates()
  expect_gt(n, before)
  # another plan's node ids, the same kernel: its exports go by position
  again <- collect(ndvi(2L), distributed = TRUE)
  expect_identical(garry:::.daemon_jit_creates(), n)
  .gg_identical(again, got)
  .gg_close(got, collect(ndvi(0L), distributed = FALSE))

  x <- function() .gg_masked_composite(open = 1L, single = TRUE)
  before <- garry:::.daemon_jit_creates()
  got <- collect(x(), distributed = TRUE)
  expect_identical(garry_last_route(), "composite_direct")
  n <- garry:::.daemon_jit_creates()
  expect_gt(n, before)
  .gg_identical(collect(x(), distributed = TRUE), got)
  expect_identical(garry:::.daemon_jit_creates(), n)
})

test_that("a whole-grid kernel's key holds all it closes over", {
  spec <- list(
    F = NULL, mask_chain = list(), halo = 1L, op = "median", nan_rm = TRUE,
    fmask_srcs = integer(0), device = "cpu",
    band_affine = list(list(scale = numeric(0), offset = numeric(0))),
    grid = .gg_grid
  )
  key <- garry:::.gd_cube_key
  expect_identical(key(spec), key(spec))
  for (other in list(
    list(halo = 2L),
    list(op = "mean"),
    list(nan_rm = FALSE),
    list(fmask_srcs = 1L),
    list(band_affine = list(list(scale = 2, offset = 0))),
    list(grid = grid_spec("EPSG:3857", extent = c(0, 0, 600, 300), dims = c(60L, 30L), dtype = "f32"))
  )) {
    changed <- spec
    changed[names(other)] <- other
    expect_false(identical(key(changed), key(spec)))
  }
})
