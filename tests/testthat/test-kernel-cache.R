# Decision D14: anvl's LRU jit cache is the kernel cache, and a regular
# chunk grid submits at most 4 distinct shapes per stage (D4). Compute
# stages grow their edge chunks to the modal shape, so they submit one.


test_that("a ragged chunk grid submits at most 4 shapes per stage", {
  f <- fixture_gradient_f32()          # 60 x 40
  a <- lazy_source(f)
  expr <- focal_map(a * 2, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)

  # the distinct input shapes each stage's kernel is submitted
  seen <- list()
  real <- garry:::.host_kernel
  testthat::local_mocked_bindings(
    .host_kernel = function(ck, fn, dev) {
      jf <- real(ck, fn, dev)
      function(inputs) {
        sh <- paste(dim(inputs[[1L]]), collapse = "x")
        seen[[ck]] <<- unique(c(seen[[ck]], sh))
        jf(inputs)
      }
    },
    .package = "garry"
  )
  withr::local_options(garry.chunk_target_px = 17 * 23,   # ragged everywhere
                       garry.pad_edge_chunks = FALSE)
  whole <- collect(expr)

  expect_length(seen, 1L)
  expect_lte(length(seen[[1L]]), 4L)
  # The compute stage really did see several chunk shapes.
  expect_gte(length(seen[[1L]]), 2L)

  # Grown edge chunks: the compute stage submits the modal shape alone,
  # with the same values
  withr::local_options(garry.pad_edge_chunks = TRUE)
  seen <- list()
  got <- collect(expr)
  expect_length(seen[[1L]], 1L)
  expect_identical(dim(got), dim(whole))
  expect_identical(as.vector(got), as.vector(whole))
})

test_that("a kernel signature that fails stops the run", {
  skip_if_not(.kernels_outlive_runs(), "no kernel is signed where none outlives a run")
  testthat::local_mocked_bindings(.stage_kernel_sig = function(...) stop("no signature"))
  expect_error(
    collect(lazy_source(fixture_gradient_f32()) * 7, distributed = FALSE),
    "no signature"
  )
})

test_that("a hit at the cap keeps the kernel cache, a miss empties it", {
  e <- .local_kernel_cache()
  fn <- function(inp) inp
  cap <- garry:::.kernel_cache_max
  for (i in seq_len(cap)) {
    e[[paste0("k", i)]] <- fn
  }
  expect_identical(garry:::.daemon_kernel("k1", NULL), fn)
  expect_length(ls(e, all.names = TRUE), cap)
  garry:::.daemon_kernel("fresh", fn)
  expect_identical(ls(e, all.names = TRUE), "fresh")
  expect_error(garry:::.daemon_kernel("cold", NULL), "garry_jit_miss")
})

test_that("a warm-up holds to the kernel cache's cap", {
  e <- .local_kernel_cache()
  cap <- garry:::.kernel_cache_max
  for (i in seq_len(cap)) {
    e[[paste0("k", i)]] <- identity
  }
  sp <- list(
    ck = "warm", device = "cpu", fn = function(inp) list(inp[[1L]] + 1),
    dtypes = "f32", outers = 1L, nr = 2L, nc = 2L
  )
  garry:::.daemon_warm_jit(list(sp))
  expect_lte(length(ls(e, all.names = TRUE)), cap)
})

test_that("a host kernel's key follows anvl's default dtypes", {
  skip_on_os("mac") # the host cache is not used there
  testthat::local_mocked_bindings(.daemon_kernel = function(ck, fn, dev) ck)
  plain <- garry:::.host_kernel("k", identity, NULL)
  withr::local_options(anvl.default_dtypes = list(float = "f64"))
  expect_false(identical(garry:::.host_kernel("k", identity, NULL), plain))
})

test_that("the single route and the host quantizer share that cache", {
  skip_on_os("mac") # the host cache is not used there
  e <- .local_kernel_cache()
  x <- lazy_source(fixture_gradient_f32()) * 3.25
  invisible(collect(x, distributed = FALSE))
  expect_length(ls(e, all.names = TRUE), 1L)
  n <- garry:::.daemon_jit_creates()
  invisible(collect(lazy_source(fixture_gradient_f32()) * 3.25, distributed = FALSE))
  expect_identical(garry:::.daemon_jit_creates(), n)
  garry:::.g_quantize_jit(0.01, 0, -32768, "i16")
  expect_length(ls(e, all.names = TRUE), 2L)
})
