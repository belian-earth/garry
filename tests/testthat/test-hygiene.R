# Daemon memory hygiene (workstream B): .garry_malloc_trim returns
# arena pages (glibc), .daemon_hygiene(deep) evicts the jit cache, and
# deferred passes keep each daemon's transients bounded (issue #25).
# test-jit-key-only.R runs garry_pool_hygiene() on live pools.

test_that(".garry_malloc_trim runs (glibc) and is a safe no-op elsewhere", {
  got <- garry:::.garry_malloc_trim()
  expect_true(isTRUE(got) || isFALSE(got))
  if (identical(Sys.info()[["sysname"]], "Linux")) expect_true(got)
})

test_that(".daemon_hygiene deep-evicts the jit cache", {
  e <- .local_kernel_cache()
  e[["spike"]] <- function() 1
  garry:::.daemon_hygiene(deep = TRUE)
  expect_length(ls(e), 0L)
})

test_that(".daemon_gc_after defers the pass until the transient budget fills", {
  st <- garry:::.daemon_gc_state
  testthat::local_mocked_bindings(.daemon_gc_budget_mb = 1)
  on.exit({
    st$bytes <- 0
    st$since_full <- 0
  }, add = TRUE)
  st$bytes <- 0
  expect_false(garry:::.daemon_gc_after(0.4 * 2^20))
  expect_false(garry:::.daemon_gc_after(0.4 * 2^20))
  expect_equal(st$bytes, 0.8 * 2^20)
  expect_true(garry:::.daemon_gc_after(0.4 * 2^20))   # 1.2 MB >= 1 MB
  expect_equal(st$bytes, 0)
  # a single big transient always runs the pass
  expect_true(garry:::.daemon_gc_after(8 * 2^20))
  # passes are minor collections until four budgets of transients have
  # passed since the last full one
  st$bytes <- 0
  st$since_full <- 0
  for (i in 1:3) garry:::.daemon_gc_after(1.2 * 2^20)
  expect_equal(st$since_full, 3.6 * 2^20)
  garry:::.daemon_gc_after(1.2 * 2^20) # 4.8 MB >= 4 MB: full
  expect_equal(st$since_full, 0)
  # one task over four budgets is collected in full at once
  garry:::.daemon_gc_after(5 * 2^20)
  expect_equal(st$since_full, 0)
})

test_that(".payload_bytes sizes raw payloads, R vectors and lists", {
  pb <- garry:::.payload_bytes
  expect_identical(pb(raw(10)), 10)
  expect_identical(pb(numeric(3)), 24)
  expect_identical(pb(integer(3)), 12)
  expect_identical(pb(list(raw(4), list(numeric(1), "x"))), 12)
})

test_that("gd task bodies report their transients to the deferred pass", {
  st <- garry:::.daemon_gc_state
  on.exit(st$bytes <- 0, add = TRUE)
  dir <- withr::local_tempdir()
  bin <- function(name, v) {
    f <- file.path(dir, name)
    writeBin(as.numeric(v), f, size = 4L)
    f
  }
  fm <- bin("fm.bin", rep(1, 6))
  shared <- bin("shared.bin", rep(1, 6))
  band <- bin("b.bin", 1:6)
  st$bytes <- 0
  garry:::.gd_compute_mask(
    list(fmask_bins = c(fm, shared), out_bins = file.path(dir, c("m1.bin", "m2.bin")), free = fm),
    list(chain = list(), halo = 0L, ny = 2L, nx = 3L, dev = "cpu", ck = "k-gc-mask")
  )
  expect_gte(st$bytes, 2 * 6 * 4)
  expect_false(file.exists(fm))
  expect_true(file.exists(shared))
  st$bytes <- 0
  garry:::.gd_compute_masked_band(
    list(cubes = list(band), rows = NULL, ck = "k-gc-band"),
    list(
      kernels = list(`k-gc-band` = list(
        F = NULL, op = "median", nan_rm = TRUE, masked = FALSE,
        affine = list(scale = numeric(0), offset = numeric(0))
      )),
      ny = 2L, nx = 3L, dev = "cpu", mask_bins = character(0), mask_y0 = 0L
    )
  )
  expect_gte(st$bytes, 6 * 4)
})

test_that("a cached pipeline kernel keeps no task's frame alive", {
  built <- list(
    function(k) garry:::.gd_lean_fn(k$F, k$op, k$nan_rm, k$affine, k$masked),
    function(k) garry:::.gd_mask_fn(k$chain, k$halo),
    function(k) garry:::.gd_band_fn(identity, k$op)
  )
  for (build in built) {
    gone <- FALSE
    kernel <- local({
      k <- list(
        F = NULL, op = "median", nan_rm = TRUE, affine = NULL, masked = FALSE,
        chain = list(), halo = 0L
      )
      reg.finalizer(environment(), function(e) gone <<- TRUE)
      build(k)
    })
    gc()
    expect_true(gone)
    expect_true(is.function(kernel))
  }
})

test_that("the read-only writer's mapped planes reach the deferred pass", {
  # A mapped plane pins its shared memory until a collection unmaps it,
  # even after the reader has dropped the region.
  st <- garry:::.daemon_gc_state
  on.exit(st$bytes <- 0, add = TRUE)
  p <- tempfile(fileext = ".tif")
  file.copy(fixture_gradient_f32(), p)
  planes <- list(as.numeric(1:6))
  sh <- mori::share(planes)
  st$bytes <- 0
  garry:::.daemon_write_shared(
    p, 0L, 0L, list(name = mori::shared_name(sh), nr = 2L, nc = 3L), 0L
  )
  expect_identical(garry:::.daemon_write_close(), character(0))
  expect_gte(st$bytes, 6 * 8)
})

test_that("the writer reopens a GTiff with threaded compression", {
  p <- tempfile(fileext = ".tif")
  file.copy(fixture_gradient_f32(), p)
  # the handle does not report its options, so hold the open that sets them
  asked <- NULL
  real <- methods::new
  ds <- testthat::with_mocked_bindings(
    gdal_open_update(p),
    new = function(...) {
      asked <<- list(...)$open_options
      real(...)
    },
    .package = "methods"
  )
  on.exit(ds$close(), add = TRUE)
  expect_identical(asked, "NUM_THREADS=ALL_CPUS")
  ds$write(1L, 0L, 0L, 60L, 40L, as.numeric(t(matrix(2, 40, 60))))
  ds$close()
  expect_equal(unique(as.vector(gdal_read_window(p, 1L, 0L, 0L, 60L, 40L))), 2)
})
