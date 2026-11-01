# Kernels with a body of their own, on daemons: a chunk's program runs on a
# compute profile, and what comes back is held to the pure-R reference of the
# kernel's own test file. test-route-matrix.R owns a plan being equal across
# routes; this file holds that each body reaches a daemon whole, with the
# values it closes over, at a chunk target that splits the plan.

# A scan or a patch has no chain to place: it is a compute stage of its own.
.rk_stage <- .leg(decision = "none")

local({
  local_pools(2, 1)

  test_that("a hampel scan on daemons holds its reference", {
    expect_plan(hampel_smooth(.hampel_stack(), k = 2, t0 = 3),
                .outer_last(.ref_hampel(.hampel_cube(), 2, 3)),
                "f32", legs = list(.rk_stage), px = 30, file = FALSE, tolerance = 1e-5)
  })

  test_that("a geomedian on daemons holds its reference", {
    expect_plan(reduce_over(.mb_cube(), geomedian(iters = 6L), over = "t"),
                .outer_last(.ref_pixels(.mb_values(), function(Y) .ref_wz(Y, iters = 6L))),
                "f32", legs = list(.rk_stage), px = 30, file = FALSE, tolerance = 1e-4)
  })

  test_that("a custom reducer on daemons runs over every chunk", {
    range_fn <- function(x, dims) {
      g_max(x, dims = dims, nan_rm = TRUE) - g_min(x, dims = dims, nan_rm = TRUE)
    }
    a <- lazy_source(fixture_gradient_f32())
    m <- .fixture_values(60, 40)
    expect_plan(reduce_over(lazy_stack(list(a + 1, a * 2)), range_fn, "t", nan_rm = TRUE),
                abs(m * 2 - (m + 1)), "f32", legs = list(.comp), px = 400, file = FALSE)
  })

  test_that("a patch stage on daemons holds its value", {
    expect_plan(.toy_patch(), .toy_patch_want(), "f32", legs = list(.rk_stage), px = 400,
                file = FALSE, tolerance = 1e-6)
  })

  test_that("min and max on daemons leave all-nodata pixels as NaN", {
    m <- .fixture_values(60, 40)
    m[m <= 2000] <- NaN
    for (op in c("min", "max")) {
      expect_plan(reduce_over(.allnan_stack(), op, "t"), if (op == "min") m else m * 2, "f32",
                  legs = list(.comp), px = 400, file = FALSE, info = op)
    }
  })

  test_that("a bilateral window on daemons holds its reference", {
    x <- focal_map(.bilateral_source(), fn = bilateral_focal(sigma_r = 3), radius = 1L)
    expect_plan(x, .ref_bilateral(.bilateral_plane(), 1, 3), "f32", legs = list(.comp), px = 30,
                file = FALSE, tolerance = 1e-4)
  })
})
