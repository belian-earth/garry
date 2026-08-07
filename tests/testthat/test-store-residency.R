# PR1 of the placement work (design/placement-cost-pass.md,
# scheduling-review-2026-07-29.md): store residency accounting. Gates:
# compute outputs carry store bytes and the store gate cannot deadlock
# under a starved budget (escape hatches serialise instead); the fused
# store estimate prices the kernel EXPORT, not the source window; the
# /dev/shm backstop degrades to a serial trickle, never a stall.


test_that(".store_region_mb prices fused exports, not source windows", {
  dims <- c(x = 512L, y = 512L)
  # Element bytes come from the region dtype under the run's store
  # mode: raw keeps f32 at 4 B; f64 (raw or not) and any doubles
  # fallback are 8 B (design/f64-store.md).
  expect_identical(garry:::.store_bytes_of("f32", TRUE), 4)
  expect_identical(garry:::.store_bytes_of("f32", FALSE), 8)
  expect_identical(garry:::.store_bytes_of("f64", TRUE), 8)
  expect_identical(garry:::.store_bytes_of("f64", FALSE), 8)
  # A 145-band coalesced read window in raw f32...
  full <- garry:::.store_region_mb(c(256L, 256L), dims, 0L, 145, 4)
  # ...whose fused kernel exports ONE band: ~145x apart. Pricing the
  # fused region from the source window would serialise the fleet.
  fused <- garry:::.store_region_mb(c(256L, 256L), dims, 0L, 1, 4)
  expect_equal(full / fused, 145)
  expect_equal(fused, 256 * 256 * 4 / 2^20)
  # pad rings and the double-precision path price in
  expect_equal(garry:::.store_region_mb(c(256L, 256L), dims, 2L, 1, 8),
               260 * 260 * 8 / 2^20)
  # windows clip to the grid
  expect_equal(garry:::.store_region_mb(c(1024L, 1024L), dims, 0L, 1, 4),
               512 * 512 * 4 / 2^20)
})

test_that(".garry_shm_free_mb reads tmpfs free space or degrades to NA", {
  v <- garry:::.garry_shm_free_mb()
  if (dir.exists("/dev/shm")) {
    expect_true(is.finite(v) && v > 0)
  } else {
    expect_true(is.na(v))
  }
})

test_that("a starved store budget serialises but completes correctly", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  f <- fixture_gradient_f32()

  local_pools(2, 1, gdal_config = TRUE)
  # Force many chunks AND a store budget below any single region: every
  # launch goes through the no-inflight escape hatch. With compute
  # outputs now feeding the same gate, this exercises the read/compute
  # alternation at the budget wall; a deadlock here would hang the test.
  old <- options(garry.chunk_target_px = 400,
                 garry.read_budget_mb = 0.0001)
  on.exit(options(old), add = TRUE)

  a <- lazy_source(f)
  b <- lazy_source(f, graph = a@graph)
  p <- plan_lazy(reduce_over(lazy_stack(list(a + 1, b * 2)), "median",
                             "t", nan_rm = TRUE))
  expect_equal(execute_plan_mirai(p), execute_plan(p), tolerance = 1e-12)
})

test_that("the /dev/shm backstop clamps the budget without stalling", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  f <- fixture_gradient_f32()

  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  # Pretend /dev/shm is nearly full: the clamp floors at store_mb_max
  # and the forced flush path runs every refresh. The run must still
  # complete and match the oracle.
  testthat::local_mocked_bindings(
    .garry_shm_free_mb = function() 1,
    .package = "garry")
  a <- lazy_source(f)
  p <- plan_lazy(reduce_over(lazy_stack(list(a + 1, a * 2)), "median",
                             "t", nan_rm = TRUE))
  expect_equal(execute_plan_mirai(p), execute_plan(p), tolerance = 1e-12)
})
