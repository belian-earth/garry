# Daemon memory hygiene (workstream B): .garry_malloc_trim returns
# arena pages (glibc), .daemon_hygiene(deep) evicts the jit cache, and
# a post-hygiene run on the same pools stays correct (the jit-miss
# resend covers evicted key-only launches).

test_that(".garry_malloc_trim runs (glibc) and is a safe no-op elsewhere", {
  got <- garry:::.garry_malloc_trim()
  expect_true(isTRUE(got) || isFALSE(got))
  if (identical(Sys.info()[["sysname"]], "Linux")) expect_true(got)
})

test_that(".daemon_hygiene deep-evicts the jit cache", {
  e <- garry:::.daemon_cache
  e[["spike"]] <- function() 1
  expect_true(length(ls(e)) >= 1L)
  garry:::.daemon_hygiene(deep = TRUE)
  expect_length(ls(e), 0L)
})

test_that("garry_pool_hygiene runs and the pools stay serviceable", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  local_pools(2, 1)
  f <- fixture_gradient_f32()
  want <- collect(lazy_source(f) + 1, distributed = FALSE)
  got1 <- collect(lazy_source(f) + 1, distributed = TRUE)
  garry_pool_hygiene(deep = TRUE)      # wipes every daemon jit cache
  got2 <- collect(lazy_source(f) + 1, distributed = TRUE)
  expect_equal(got1, want, tolerance = 1e-6, ignore_attr = TRUE)
  expect_equal(got2, want, tolerance = 1e-6, ignore_attr = TRUE)
})
