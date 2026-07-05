# Decision D14: anvl's LRU jit cache is the kernel cache, and a regular
# chunk grid submits at most 4 distinct shapes per stage (D4), so each
# stage compiles at most 4 executables.

skip_if_not_installed("anvl")

test_that("a ragged chunk grid submits at most 4 shapes per stage", {
  f <- fixture_gradient_f32()          # 60 x 40
  a <- lazy_source(f)
  expr <- focal(a * 2, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)

  old <- options(garry.chunk_target_px = 17 * 23,   # ragged everywhere
                 garry.exec_stats = TRUE)
  on.exit(options(old))
  got <- collect(expr)
  stats <- attr(got, "garry_exec_stats")

  for (shapes in stats) {
    expect_lte(length(shapes), 4L)
  }
  # The compute stage really did see several chunks.
  compute_shapes <- stats[[2L]]
  expect_gte(length(compute_shapes), 2L)
})

test_that("cached dispatch is fast after first-shape compilation", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  expr <- a * 2 + 1

  # First collect pays trace+compile; second must hit anvl's LRU cache.
  t1 <- system.time(collect(expr))["elapsed"]
  t2 <- system.time(collect(expr))["elapsed"]
  expect_lt(unname(t2), unname(t1) + 0.5)   # sanity: no recompile blowup
  # Median cached call on a chunk this size is single-digit ms; allow CI
  # slack while still catching a recompile-per-chunk regression.
  expect_lt(unname(t2), 2.0)
})
