# Routed dispatch (design/routed-dispatch.md) — since 2026-08-02 the
# ONLY dispatch mode (the anonymous pool was excised after routing
# proved strictly dominant). Gates: profile creation / teardown /
# generation replacement; distributed == single (map/reduce/scan,
# streamed write); tasks SPREAD across profiles; composite-direct
# round-robins its jobs; task-log rows carry daemon identity; scan
# tasks are CONFINED to the designated profiles with mixed per-role
# masks.

skip_if_not_installed("anvl")
skip_if_not_installed("mirai")
skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")

test_that("routed pools create N width-1 profiles and tear down clean", {
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
  withr::local_options(garry.placement = "rules",
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
  withr::local_options(garry.chunk_target_px = 600)
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
  withr::local_options(garry.chunk_target_px = 600)
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
  garry_daemons(2, 2, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  x <- .gg_masked_composite()
  want <- collect(x, distributed = FALSE)
  got <- collect(x, distributed = TRUE)
  expect_identical(garry_last_route(), "composite_direct")
  .gg_close(got, want)
})

test_that("scan tasks are CONFINED to the designated profiles (C3)", {
  withr::local_options(garry.chunk_target_px = 600)
  garry_daemons(2, 4, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  tlog <- withr::local_tempfile(fileext = ".csv")
  withr::local_options(garry.task_log = tlog)
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
  p <- collect(sc, plan_only = TRUE)
  scan_sid <- Filter(function(s) any(vapply(s@members, function(id)
    S7::S7_inherits(garry:::graph_get(p@graph, id), garry:::ScanNode),
    logical(1))), p@stages)[[1L]]@id
  got <- execute_plan_mirai(p)
  want <- execute_plan(p)
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
  tl <- read.csv(tlog)
  scan_slots <- unique(tl$slot[tl$event == "launch" &
                                 grepl(sprintf("^s%d_", scan_sid), tl$key)])
  expect_gte(length(scan_slots), 1L)
  expect_true(all(scan_slots %in% c("garry_comp_1", "garry_comp_2")))
  # exact per-profile warmth: an immediate rerun (fresh run id, warm
  # daemons) stays correct through the key-only path
  got2 <- execute_plan_mirai(p)
  expect_equal(got2, want, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("scan plans get mixed per-role masks on routed pools (C3)", {
  skip_on_os(c("windows", "mac"))
  skip_if(!nzchar(Sys.which("taskset")), "taskset absent")
  skip_if(garry:::.garry_cores()$logical < 8L, "needs >= 8 cores")
  withr::local_options(garry.chunk_target_px = 600)
  garry_daemons(2, 4, gdal_config = FALSE)
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
  invisible(collect(sc, distributed = TRUE))
  cpus_of <- function(pid) {
    s <- readLines(sprintf("/proc/%d/status", pid))
    ln <- grep("^Cpus_allowed_list", s, value = TRUE)
    parts <- strsplit(sub(".*:\\s*", "", ln), ",")[[1L]]
    sum(vapply(parts, function(r) {
      ab <- as.integer(strsplit(r, "-")[[1L]])
      if (length(ab) == 1L) 1L else ab[[2L]] - ab[[1L]] + 1L
    }, integer(1)))
  }
  pids <- garry:::.garry_state$comp_pids
  expect_length(pids, 4L)
  # scan profiles (1, 2) run fat; map profiles (3, 4) stay narrow
  expect_gt(cpus_of(pids[[1L]]), cpus_of(pids[[3L]]))
})
