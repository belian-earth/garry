# Decision D14: anvl's LRU jit cache is the kernel cache, and a regular
# chunk grid submits at most 4 distinct shapes per stage (D4). Compute
# stages grow their edge chunks to the modal shape, so they submit one.


test_that("a ragged chunk grid submits at most 4 shapes per stage", {
  f <- fixture_gradient_f32()          # 60 x 40
  a <- lazy_source(f)
  expr <- focal_map(a * 2, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)

  old <- options(garry.chunk_target_px = 17 * 23,   # ragged everywhere
                 garry.exec_stats = TRUE,
                 garry.pad_edge_chunks = FALSE)
  on.exit(options(old))
  whole <- collect(expr)
  stats <- attr(whole, "garry_exec_stats")

  for (shapes in stats) {
    expect_lte(length(shapes), 4L)
  }
  # The compute stage really did see several chunk shapes.
  compute_shapes <- stats[[2L]]
  expect_gte(length(compute_shapes), 2L)

  # Grown edge chunks: the compute stage submits the modal shape alone,
  # with the same values
  options(garry.pad_edge_chunks = TRUE)
  got <- collect(expr)
  expect_length(attr(got, "garry_exec_stats")[[2L]], 1L)
  expect_identical(dim(got), dim(whole))
  expect_identical(as.vector(got), as.vector(whole))
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
