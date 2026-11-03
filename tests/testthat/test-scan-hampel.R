# hampel_smooth(): centred rolling median/MAD despike over t. Gates: a full
# plan matches an independent pure-R reference (including NaN gaps and series
# ends); t0 = 0 degenerates to a rolling median; gaps stay gaps. The stack and
# the reference are in helper-kernels.R; test-route-kernels.R runs them on
# daemons.

test_that("hampel_smooth matches the pure-R reference through a full plan", {
  raw <- .hampel_cube()
  stk <- .hampel_stack()
  for (cfg in list(c(k = 1, t0 = 3), c(k = 2, t0 = 3), c(k = 2, t0 = 0))) {
    got <- execute_plan(plan_lazy(hampel_smooth(stk, k = cfg[["k"]],
                                                t0 = cfg[["t0"]])))
    ref <- .ref_hampel(raw, cfg[["k"]], cfg[["t0"]])
    label <- glue::glue("k={cfg[['k']]} t0={cfg[['t0']]}")
    # the filter decides per pixel: it moves some cells and keeps others
    moved <- abs(ref - raw) > 0
    expect_true(any(moved, na.rm = TRUE) && !all(moved, na.rm = TRUE), label = label)
    expect_identical(is.na(got), is.na(ref), label = label)
    keep <- !is.na(ref)
    # relative: the traced medians compute in f32
    expect_lt(max(abs(got[keep] - ref[keep]) / pmax(abs(ref[keep]), 1)), 1e-4)
  }
})

test_that("gaps stay gaps; the spikes are repaired", {
  raw <- .hampel_cube()
  .expect_partial_nan(raw)
  got <- execute_plan(plan_lazy(hampel_smooth(.hampel_stack(), k = 2, t0 = 3)))
  expect_identical(is.nan(got), is.nan(raw))
  # every spike is pulled back to the scale of its window
  spikes <- which(raw > 1000)
  expect_gt(length(spikes), 0L)
  expect_lt(max(got[spikes] / raw[spikes]), 0.1)
})

test_that("hampel_smooth validates its arguments", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  expect_error(hampel_smooth(lazy_stack(list(a, a * 2)), k = 0), "positive")
  expect_error(hampel_smooth(lazy_stack(list(a, a * 2)), t0 = -1),
               "non-negative")
})
