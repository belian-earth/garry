# Strip-mined scan stages (.strip_stage_fn): a scan stage's kernel runs
# over row strips of its chunk inside one XLA program. The strips must
# reassemble to exactly the whole-chunk result.

test_that(".strip_stage_fn reassembles a kernel's strips exactly", {
  set.seed(2)
  y <- array(15 + rnorm(6 * 11 * 9, 0, 3), c(6L, 11L, 9L))
  y[runif(length(y)) < 0.15] <- NaN
  w <- matrix(rgamma(11 * 9, 4, 2), 11L, 9L)
  q <- matrix(sample(0:3, 11 * 9, TRUE), 11L, 9L)
  f <- function(ins) {
    yy <- ins[[1L]] * g_rep_t(ins[[2L]], 6L)
    list(
      cum = g_scan(
        init = 0,
        body = function(carry, v) {
          s <- carry + g_ifelse(g_is_nodata(v), 0, v)
          list(carry = s, out = s)
        },
        xs = yy
      )$out,
      mid = g_median(yy, dims = 1L, nan_rm = TRUE) + g_cast(ins[[3L]], "f32")
    )
  }
  ins <- list(g_upload(y, "f32"), g_upload(w, "f32"), g_upload(q, "i16"))
  whole <- g_download(garry:::g_jit(f)(ins))
  # 11 rows: three 3-row strips and a padded fourth; then one strip
  # short of the chunk, and a strip as tall as the chunk (runs whole)
  for (rows in c(3L, 10L, 11L)) {
    got <- g_download(garry:::g_jit(garry:::.strip_stage_fn(f, rows))(ins))
    expect_identical(got, whole)
  }
  # untraced values pass straight through
  plain <- list(y, w, q)
  expect_identical(garry:::.strip_stage_fn(function(x) x, 3L)(plain), plain)
})

# A (t, y, x) stack with gaps and a step, for the robust smoother.
.strip_stack <- function() {
  g <- graph_new()
  a <- lazy_source(fixture_gradient_f32(), graph = g)
  steps <- lapply(1:6, function(t) {
    v <- a * (1 + t / 10) + if (t >= 4) 5 else 0
    if (t %in% c(2, 5)) {
      v <- lazy_map(v, dtype = "f32", fn = function(z) {
        g_ifelse(z > 30 & z < 40, NaN, z)
      })
    }
    v
  })
  lazy_stack(steps, along = "t")
}

test_that("the planner strips scan stages only", {
  stk <- .strip_stack()
  sm <- kalman_smooth(stk, 1, 0.1, 1.4, outputs = "mean", robust_iters = 1L)
  has_scan <- function(p) {
    vapply(
      p@stages,
      function(s) {
        any(vapply(
          s@members,
          function(id) {
            S7::S7_inherits(garry:::graph_get(p@graph, id), garry:::ScanNode)
          },
          logical(1)
        ))
      },
      logical(1)
    )
  }
  withr::local_options(garry.scan_strip_px = 180)
  p <- collect(sm$mean, plan_only = TRUE)
  rows <- vapply(p@stages, function(s) s@strip_rows, integer(1))
  expect_true(any(has_scan(p)))
  expect_true(all(rows[!has_scan(p)] == 0L))
  expect_true(all(rows[has_scan(p)] == 3L)) # 180 cells over a 60-wide chunk
  withr::local_options(garry.scan_strip_px = 0)
  p0 <- collect(sm$mean, plan_only = TRUE)
  expect_true(all(
    vapply(p0@stages, function(s) s@strip_rows, integer(1)) == 0L
  ))
  # stripped and whole kernels never share a jit cache key
  sid <- which(has_scan(p))[[1L]]
  expect_false(identical(
    garry:::.stage_kernel_sig(p@graph, p@stages[[sid]]),
    garry:::.stage_kernel_sig(p0@graph, p0@stages[[sid]])
  ))
})

test_that("stripped scan stages equal whole chunks, in process and on daemons", {
  stk <- .strip_stack()
  sm <- kalman_smooth(stk, 1, 0.1, 1.4, robust_iters = 1L)
  run <- function(px, chunk_px, distributed) {
    withr::local_options(
      garry.scan_strip_px = px,
      garry.chunk_target_px = chunk_px
    )
    lapply(sm, collect, distributed = distributed)
  }
  whole <- run(0, 1e6, FALSE)
  # one chunk in 3-row strips (13 strips and a padded 14th), then
  # several chunks, each with its own padded strip
  expect_identical(run(180, 1e6, FALSE), whole)
  expect_identical(run(180, 600, FALSE), whole)
  local_pools(2, 2)
  expect_identical(run(180, 600, TRUE), run(0, 600, TRUE))
  expect_equal(run(180, 600, TRUE), whole, tolerance = 1e-6, ignore_attr = TRUE)
})
