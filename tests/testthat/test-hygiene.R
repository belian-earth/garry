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

# A gd task fixture on a 2 x 3 grid: a mask batch of two slices, one of them
# read by another batch too, and a band strip of three slices. A median takes
# the strip's three planes to one, so its count tells reads from outputs.
.gc_fixture <- function(dir) {
  bin <- function(name, v) {
    f <- file.path(dir, name)
    writeBin(as.numeric(v), f, size = 4L)
    f
  }
  ny <- 2L
  nx <- 3L
  band <- bin("b.bin", seq_len(ny * nx))
  list(
    ny = ny,
    nx = nx,
    plane = ny * nx * 4, # one f32 slice
    fm = bin("fm.bin", rep(1, ny * nx)),
    shared = bin("shared.bin", rep(1, ny * nx)),
    strip = c(band, band, band)
  )
}

# Run the fixture's mask batch, then its band strip, on `dev`. Returns the
# bytes each reported to the deferred pass.
.gc_run <- function(fx, dir, dev, ck) {
  st <- garry:::.daemon_gc_state
  st$bytes <- 0
  garry:::.gd_compute_mask(
    list(
      fmask_bins = c(fx$fm, fx$shared),
      out_bins = file.path(dir, c("m1.bin", "m2.bin")),
      free = fx$fm
    ),
    list(
      chain = list(),
      halo = 0L,
      ny = fx$ny,
      nx = fx$nx,
      dev = dev,
      ck = paste0(ck, "-mask")
    )
  )
  mask <- st$bytes
  st$bytes <- 0
  band_ck <- paste0(ck, "-band")
  garry:::.gd_compute_masked_band(
    list(cubes = list(fx$strip), rows = NULL, ck = band_ck),
    list(
      kernels = stats::setNames(
        list(list(
          F = NULL,
          op = "median",
          nan_rm = TRUE,
          masked = FALSE,
          affine = list(scale = numeric(0), offset = numeric(0))
        )),
        band_ck
      ),
      ny = fx$ny,
      nx = fx$nx,
      dev = dev,
      mask_bins = character(0),
      mask_y0 = 0L
    )
  )
  c(mask = mask, band = st$bytes)
}

test_that("gd task bodies report their transients to the deferred pass", {
  st <- garry:::.daemon_gc_state
  on.exit(st$bytes <- 0, add = TRUE)
  .local_kernel_cache()
  dir <- withr::local_tempdir()
  fx <- .gc_fixture(dir)
  got <- .gc_run(fx, dir, "cpu", "k-gc")
  # What R held: the two masks written and the strip's one median plane. The
  # reads left with each task and took no gc.
  expect_equal(got[["mask"]], 2 * fx$plane)
  expect_equal(got[["band"]], fx$plane)
  expect_false(file.exists(fx$fm))
  expect_true(file.exists(fx$shared))
})

test_that("on a device the deferred pass also counts the reads R held", {
  st <- garry:::.daemon_gc_state
  on.exit(st$bytes <- 0, add = TRUE)
  .local_kernel_cache()
  # No card here, so name the CPU as a device: that takes the device's branch.
  testthat::local_mocked_bindings(.exec_device = function(device) "cpu")
  dir <- withr::local_tempdir()
  fx <- .gc_fixture(dir)
  got <- .gc_run(fx, dir, "cpu", "k-gc-dev")
  # The mask batch's two reads and its two masks written; the strip's three
  # reads, which outweigh its median plane.
  expect_equal(got[["mask"]], 2 * 2 * fx$plane)
  expect_equal(got[["band"]], length(fx$strip) * fx$plane)
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
