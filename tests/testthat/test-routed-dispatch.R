# Routed dispatch (design/routed-dispatch.md), the only dispatch mode.
# Gates: profile creation, teardown and generation replacement; tasks
# SPREAD across profiles; composite-direct round-robins its jobs;
# task-log rows carry daemon identity; scan tasks are CONFINED to the
# designated profiles with mixed per-role masks. test-route-matrix.R
# holds that each route computes the same plan.

test_that("routed pools create N width-1 profiles and tear down clean", {
  local_pools(1, 2)
  expect_identical(garry:::.comp_profiles(), c("garry_comp_1", "garry_comp_2"))
  expect_identical(garry:::.comp_n(), 2L)
  expect_true(garry_daemons_set())
  expect_length(garry:::.garry_state$comp_pids, 2L)
  # 1 reader + 2 compute + the writer, none of them this process
  pids <- garry:::.garry_state$pool_pids
  expect_length(pids, 4L)
  expect_false(Sys.getpid() %in% pids)
  garry:::.garry_abi_check(garry:::.comp_profiles())
  expect_true(garry:::.garry_state$abi_ok)
  # narrower re-creation replaces the generation (no stale profiles), and
  # a new generation has not been checked against the host
  garry_daemons(1, 1, gdal_config = FALSE)
  expect_identical(garry:::.comp_profiles(), "garry_comp_1")
  expect_identical(garry:::.gd_n_compute("garry_comp_2"), 0L)
  expect_length(garry:::.garry_state$pool_pids, 3L)
  expect_null(garry:::.garry_state$abi_ok)
  garry_daemons(0, 0, gdal_config = FALSE)
  expect_identical(garry:::.comp_profiles(), character(0))
  expect_false(garry_daemons_set())
  expect_length(garry:::.garry_state$pool_pids, 0L)
})

local({
  local_pools(1, 2)

  test_that("tasks spread across profiles", {
    # rules placement keeps the sink stage on the compute pool: cost
    # placement fuses this whole chain onto the coalesced read
    tlog <- withr::local_tempfile(fileext = ".csv")
    withr::local_options(garry.placement = "rules", garry.chunk_target_px = 600, garry.task_log = tlog)
    g <- graph_new()
    a <- lazy_source(fixture_gradient_f32(), graph = g)
    x <- reduce_over(lazy_stack(list(a + 1, a * 2), along = "t"), "mean", "t")
    m <- .fixture_values(60, 40)
    got <- collect(x, distributed = TRUE)
    expect_equal(unclass(got), (m + 1 + m * 2) / 2, tolerance = 0, ignore_attr = TRUE)
    tl <- read.csv(tlog)
    tl <- tl[tl$event == "launch" & startsWith(tl$key, "s"), ]
    # both profiles run the plan's own tasks, warm-ups aside
    expect_setequal(tl$slot[tl$pool == "comp"], garry:::.comp_profiles())
  })

  test_that("composite_direct round-robins through routed profiles", {
    tlog <- withr::local_tempfile(fileext = ".csv")
    withr::local_options(garry.task_log = tlog)
    invisible(collect(.gg_masked_composite(), distributed = TRUE))
    expect_identical(garry_last_route(), "composite_direct")
    tl <- read.csv(tlog)
    bands <- table(tl$slot[tl$event == "launch" & startsWith(tl$key, "b")])
    expect_setequal(names(bands), garry:::.comp_profiles())
    expect_identical(as.vector(bands[[1L]]), as.vector(bands[[2L]]))
  })
})

test_that("scan tasks are CONFINED to the designated profile, with mixed masks (C3)", {
  # a third daemon is the floor: at two, the narrow mask equals the fat one
  withr::local_options(garry.chunk_target_px = 600, garry.scan_profiles = 1L)
  local_pools(1, 3)
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
  # the running sum over t: the first slice, then both
  m <- .fixture_values(60, 40)
  want <- aperm(array(c(m + 1, m + 1 + m * 2), c(40L, 60L, 2L)), c(3L, 1L, 2L))
  got <- execute_plan_mirai(p)
  expect_equal(unclass(got), want, tolerance = 0, ignore_attr = TRUE)
  tl <- read.csv(tlog)
  scan_slots <- unique(tl$slot[tl$event == "launch" &
                                 grepl(sprintf("^s%d_", scan_sid), tl$key)])
  expect_identical(scan_slots, "garry_comp_1")
  # exact per-profile warmth: an immediate rerun (fresh run id, warm
  # daemons) stays correct through the key-only path
  got2 <- execute_plan_mirai(p)
  expect_equal(unclass(got2), want, tolerance = 0, ignore_attr = TRUE)

  skip_on_os(c("windows", "mac"))
  skip_if(!nzchar(Sys.which("taskset")), "taskset absent")
  skip_if(garry:::.garry_cores()$logical < 8L, "needs >= 8 cores")
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
  expect_length(pids, 3L)
  # the scan profile runs fat; the map profiles stay narrow
  expect_gt(cpus_of(pids[[1L]]), cpus_of(pids[[2L]]))
  expect_gt(cpus_of(pids[[1L]]), cpus_of(pids[[3L]]))
})
