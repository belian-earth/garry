# hampel_smooth(): centred rolling median/MAD despike over t. Gates:
# full plan matches an independent pure-R reference (including NaN
# gaps and series ends); t0 = 0 degenerates to a rolling median; gaps
# stay gaps; distributed == single-threaded.

skip_if_not_installed("anvl")

# independent reference: per-pixel clipped-window hampel
.ref_hampel <- function(v, k, t0) {
  T_ <- length(v); out <- v
  for (t in seq_len(T_)) {
    w <- v[max(1L, t - k):min(T_, t + k)]
    med <- stats::median(w, na.rm = TRUE)
    mad <- 1.4826 * stats::median(abs(w - med), na.rm = TRUE)
    if (is.finite(v[t]) && abs(v[t] - med) > t0 * mad) out[t] <- med
  }
  out
}

.hampel_fixture <- function() {
  f <- fixture_gradient_f32()
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  # 6 slices with structure, spikes, and NaN gaps
  layers <- list(a, a * 1.02, a * 40, a * 0.98,
                 lazy_map(a, dtype = "f32",
                          fn = function(x) g_ifelse(x > 0.5, NaN, x)),
                 a * 1.01)
  lazy_stack(layers, along = "t")
}

test_that("hampel_smooth matches the pure-R reference through a full plan", {
  stk <- .hampel_fixture()
  for (cfg in list(c(k = 1, t0 = 3), c(k = 2, t0 = 3), c(k = 2, t0 = 0))) {
    got <- execute_plan(plan_lazy(hampel_smooth(stk, k = cfg[["k"]],
                                                t0 = cfg[["t0"]])))
    raw <- execute_plan(plan_lazy(stk))
    ref <- raw
    for (j in seq_len(dim(raw)[2])) for (i in seq_len(dim(raw)[3]))
      ref[, j, i] <- .ref_hampel(raw[, j, i], cfg[["k"]], cfg[["t0"]])
    expect_identical(is.na(got), is.na(ref),
                     label = sprintf("k=%d t0=%g", cfg[["k"]], cfg[["t0"]]))
    keep <- !is.na(ref)
    # relative: the traced medians compute in f32, and the fixture's
    # values run to ~1e4 where f32 eps exceeds any absolute tolerance
    expect_lt(max(abs(got[keep] - ref[keep]) / pmax(abs(ref[keep]), 1)), 1e-4)
  }
})

test_that("gaps stay gaps; the spike slice is repaired", {
  stk <- .hampel_fixture()
  raw <- execute_plan(plan_lazy(stk))
  got <- execute_plan(plan_lazy(hampel_smooth(stk, k = 2, t0 = 3)))
  # slice 5's NaN holes survive
  expect_identical(is.na(got[5, , ]), is.na(raw[5, , ]))
  # slice 3 (x40 spike) is pulled back to the neighbourhood median scale
  keep <- !is.na(raw[3, , ]) & raw[3, , ] > 0
  expect_lt(max(got[3, , ][keep] / raw[3, , ][keep]), 0.1)
})

test_that("hampel scan: distributed == single-threaded", {
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE), "garry not installed")
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")

  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  p <- plan_lazy(hampel_smooth(.hampel_fixture(), k = 2, t0 = 3))
  expect_equal(execute_plan_mirai(p), execute_plan(p), tolerance = 1e-6)
})

test_that("hampel_smooth validates its arguments", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  expect_error(hampel_smooth(lazy_stack(list(a, a * 2)), k = 0), "positive")
  expect_error(hampel_smooth(lazy_stack(list(a, a * 2)), t0 = -1),
               "non-negative")
})
