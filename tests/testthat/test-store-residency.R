# PR1 of the placement work (design/placement-cost-pass.md,
# scheduling-review-2026-07-29.md): store residency accounting. The
# fused store estimate prices the kernel EXPORT, not the source window.
# test-read-budget.R starves the gate this estimate feeds.

test_that(".store_region_mb prices fused exports, not source windows", {
  dims <- c(x = 512L, y = 512L)
  # Element bytes come from the region dtype under the run's store
  # mode: raw keeps f32 at 4 B; f64 (raw or not) and any doubles
  # fallback are 8 B (design/f64-store.md).
  expect_identical(garry:::.store_bytes_of("f32"), 4)
  expect_identical(garry:::.store_bytes_of("f64"), 8)
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
