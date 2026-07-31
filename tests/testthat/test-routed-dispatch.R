# Routed dispatch C1 substrate (design/routed-dispatch.md): the compute
# pool as N width-1 direct-connection mirai profiles. Gates: profile
# creation / teardown / generation replacement; distributed == single
# through the routed scheduler (map/reduce/scan, streamed write);
# tasks SPREAD across profiles (per-profile slots work); the
# composite-direct route round-robins its jobs; task-log rows carry
# the daemon identity in the slot column.

skip_if_not_installed("anvl")
skip_if_not_installed("mirai")
skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")

test_that("routed pools create N width-1 profiles and tear down clean", {
  withr::local_options(garry.routed_dispatch = TRUE)
  garry_daemons(2, 3, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  expect_identical(garry:::.comp_profiles(),
                   c("garry_comp_1", "garry_comp_2", "garry_comp_3"))
  expect_identical(garry:::.comp_n(), 3L)
  expect_true(garry_daemons_set())
  expect_gte(length(garry:::.garry_state$comp_pids), 3L)
  # narrower re-creation replaces the generation (no stale profiles)
  garry_daemons(2, 1, gdal_config = FALSE)
  expect_identical(garry:::.comp_profiles(), "garry_comp_1")
  expect_identical(garry:::.gd_n_compute("garry_comp_3"), 0L)
  garry_daemons(0, 0, gdal_config = FALSE)
  expect_identical(garry:::.comp_profiles(), "garry_compute")
  expect_false(garry_daemons_set())
})

test_that("routed distributed == single, and tasks spread across profiles", {
  # rules placement keeps the sink stage on the compute pool (cost mode
  # fuses this whole chain onto the coalesced read — nothing to spread)
  withr::local_options(garry.routed_dispatch = TRUE,
                       garry.placement = "rules",
                       garry.chunk_target_px = 600)
  garry_daemons(2, 3, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  tlog <- withr::local_tempfile(fileext = ".csv")
  withr::local_options(garry.task_log = tlog)
  f <- fixture_gradient_f32()
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  x <- reduce_over(lazy_stack(list(a + 1, a * 2), along = "t"), "mean", "t")
  got <- collect(x, distributed = TRUE)
  want <- collect(x, distributed = FALSE)
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
  tl <- read.csv(tlog)
  used <- unique(tl$slot[grepl("^garry_comp_", tl$slot)])
  expect_gte(length(used), 2L)         # profiles genuinely share the work
})

test_that("a scan plan runs routed == single", {
  withr::local_options(garry.routed_dispatch = TRUE,
                       garry.chunk_target_px = 600)
  garry_daemons(2, 2, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  f <- fixture_gradient_f32()
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  body <- function(xs, margin) {
    g_scan(init = 0, body = function(carry, v) {
      s <- carry + v
      list(carry = s, out = s)
    }, xs = xs[[1L]])$out
  }
  sc <- scan_over(lazy_stack(list(a + 1, a * 2), along = "t"), body,
                  over = "t")
  got <- collect(sc, distributed = TRUE)
  want <- collect(sc, distributed = FALSE)
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("streamed writes work under routed dispatch", {
  withr::local_options(garry.routed_dispatch = TRUE,
                       garry.chunk_target_px = 600)
  garry_daemons(2, 2, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  f <- fixture_gradient_f32()
  path <- withr::local_tempfile(fileext = ".tif")
  collect(lazy_source(f) + 1, path = path, distributed = TRUE)
  want <- collect(lazy_source(f) + 1, distributed = FALSE)
  got <- gdal_read_window(path, 1L, 0L, 0L, 60L, 40L)
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("composite_direct round-robins through routed profiles", {
  withr::local_options(garry.routed_dispatch = TRUE)
  garry_daemons(2, 2, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  x <- .gg_masked_composite()
  want <- collect(x, distributed = FALSE)
  got <- collect(x, distributed = TRUE)
  expect_identical(garry_last_route(), "composite_direct")
  .gg_close(got, want)
})
