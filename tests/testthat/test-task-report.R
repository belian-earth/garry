# garry_task_report(): the task-log CSV schema is locked
# (time,event,key,pool,slot,mb,store_mb,ready) and the report turns it
# from a developer trace into an operator tool: complete launch/done
# pairs, per-stage durations and queue waits, max concurrency, drain vs
# host tail.

# Every launch of a report landed, on the daemon's own clock.
.tr_timed <- function(rep) {
  expect_gt(nrow(rep$tasks), 0L)
  expect_identical(nrow(rep$tasks), as.integer(rep$events[["launch"]]))
  expect_false(anyNA(rep$tasks$t_start))
  expect_false(anyNA(rep$tasks$t_end))
  expect_true(all(rep$tasks$run_s >= 0))
  expect_true(all(is.finite(rep$tasks$wait_s)))
  expect_true(all(rep$tasks$wait_s >= -0.001))
  expect_false(is.na(rep$drain_s))
  expect_false(is.na(rep$host_tail_s))
}

# Two unmasked composites of different ops: two groups of one plan.
.gt_rd_bands <- function() {
  gA <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
  gB <- .gg_gti(list(s1 = .gg_val(100), s2 = .gg_val(50)))
  g <- graph_new()
  sl <- function(gti) lazy_stack(list(.gg_slice(gti, "s1", g), .gg_slice(gti, "s2", g)))
  list(A = reduce_over(sl(gA), "median", "t"), B = reduce_over(sl(gB), "mean", "t"))
}

local({
  local_pools(2, 1)

  test_that("garry_task_report summarises a distributed run's log", {
    tlog <- withr::local_tempfile(fileext = ".csv")
    withr::local_options(garry.task_log = tlog,
                         garry.chunk_target_px = 600)
    f <- fixture_gradient_f32()
    p <- collect(lazy_source(f) + 1, plan_only = TRUE)
    invisible(execute_plan_mirai(p))

    rep <- suppressMessages(garry_task_report(tlog))
    # events are complete pairs and every pair is summarised
    expect_identical(as.integer(rep$events[["launch"]]),
                     as.integer(rep$events[["done"]]))
    expect_identical(nrow(rep$tasks), as.integer(rep$events[["launch"]]))
    expect_identical(as.integer(rep$events[["drain_end"]]), 1L)
    expect_identical(as.integer(rep$events[["host_end"]]), 1L)
    expect_gte(rep$max_concurrency, 1L)
    .tr_timed(rep)
    # per-stage summary covers every task
    expect_identical(sum(rep$stages$n), nrow(rep$tasks))
    # timed launches: every task carries the daemon's start and end
    # times, and queue + run + harvest add back up to launch-to-done
    expect_identical(as.integer(rep$events[["start"]]), nrow(rep$tasks))
    expect_identical(as.integer(rep$events[["end"]]), nrow(rep$tasks))
    expect_false(anyNA(rep$tasks$queue_s))
    expect_false(anyNA(rep$tasks$harvest_s))
    expect_true(all(rep$tasks$queue_s >= 0))
    expect_true(all(rep$tasks$harvest_s >= 0))
    expect_equal(
      rep$tasks$queue_s + rep$tasks$run_s + rep$tasks$harvest_s,
      rep$tasks$t_done - rep$tasks$t_launch,
      tolerance = 1e-6
    )
  })

  test_that("a read-only pool write logs its reads and writes as tasks", {
    testthat::local_mocked_bindings(.copy_args = function(...) NULL, .package = "garry") # the pool write
    tlog <- withr::local_tempfile(fileext = ".csv")
    out <- withr::local_tempfile(fileext = ".tif")
    withr::local_options(garry.task_log = tlog,
                         garry.chunk_target_px = 600)
    write_tif(lazy_source(fixture_gradient_f32()), out, distributed = TRUE)
    expect_identical(garry_last_route(), "read_only")

    rep <- suppressMessages(garry_task_report(tlog))
    # every read and every write is a complete, timed task
    expect_identical(sort(unique(rep$tasks$pool)), c("read", "write"))
    expect_gt(sum(rep$tasks$pool == "read"), 1L)
    expect_identical(
      sum(rep$tasks$pool == "write"),
      sum(rep$tasks$pool == "read")
    )
    .tr_timed(rep)
    expect_identical(as.integer(rep$events[["start"]]), nrow(rep$tasks))
    expect_identical(as.integer(rep$events[["end"]]), nrow(rep$tasks))
    expect_true(all(rep$tasks$queue_s >= 0))
    # busy seconds per pool add up the tasks' run times; utilisation
    # divides the run's by its pool widths and span
    expect_identical(rep$pools$pool, c("read", "write"))
    expect_equal(
      rep$pools$busy_s,
      as.vector(tapply(rep$tasks$run_s, rep$tasks$pool, sum)),
      tolerance = 1e-3
    )
    expect_identical(rep$pools$daemons, c(2, 1))
    expect_true(all(rep$pools$util_last > 0 & rep$pools$util_last <= 1))

    # a distributed read-only collect logs its reads and its host end too
    unlink(tlog)
    invisible(collect(lazy_source(fixture_gradient_f32()), distributed = TRUE))
    expect_identical(garry_last_route(), "read_only")
    rep <- suppressMessages(garry_task_report(tlog))
    expect_identical(unique(rep$tasks$pool), "read")
    expect_false(is.na(rep$host_tail_s))
  })

  test_that("a scheduler write logs its writes and warm-ups as timed tasks", {
    tlog <- withr::local_tempfile(fileext = ".csv")
    out <- withr::local_tempfile(fileext = ".tif")
    withr::local_options(garry.task_log = tlog, garry.chunk_target_px = 600)
    f <- fixture_gradient_f32()
    f2 <- withr::local_tempfile(fileext = ".tif")
    file.copy(f, f2)
    # two files: no read can fuse this kernel, so the compute pool warms it
    write_tif(lazy_source(f) * lazy_source(f2), out, distributed = TRUE)
    expect_identical(garry_last_route(), "scheduler")
    rep <- suppressMessages(garry_task_report(tlog))
    .tr_timed(rep)
    w <- rep$tasks[rep$tasks$pool == "write", ]
    expect_gt(nrow(w), 1L)
    expect_true(all(w$slot == "write"))
    expect_identical(
      rep$pools$daemons[rep$pools$pool == "write"], 1
    )
    warm <- rep$tasks[startsWith(rep$tasks$key, "warm"), ]
    expect_identical(nrow(warm), 1L)
    expect_identical(warm$pool, "comp")
    expect_identical(warm$slot, garry:::.comp_profiles()[[1L]])
  })

  test_that("the gd routes log their tasks, and nothing without a log", {
    tlog <- withr::local_tempfile(fileext = ".csv")
    x <- .gg_masked_composite(open = 1L)
    plain <- collect(x, distributed = TRUE)
    expect_false(file.exists(tlog))
    withr::local_options(garry.task_log = tlog)
    # the fetch-ordered pipeline: a fetch per source, the mask, band strips
    # and the warm-ups
    got <- collect(x, distributed = TRUE)
    expect_identical(garry_last_route(), "composite_direct")
    expect_identical(got, plain)
    rep <- suppressMessages(garry_task_report(tlog))
    .tr_timed(rep)
    expect_setequal(rep$tasks$pool, c("read", "comp"))
    expect_identical(sort(unique(substr(rep$tasks$key, 1L, 1L))), c("b", "f", "m", "w"))
    expect_identical(rep$pools$daemons[rep$pools$pool == "comp"], 1)

    # the whole-grid kernel: fetches, then the host
    unlink(tlog)
    x1 <- .gg_masked_composite(single = TRUE)
    invisible(collect(x1, distributed = TRUE))
    expect_identical(garry_last_route(), "composite_direct")
    rep <- suppressMessages(garry_task_report(tlog))
    .tr_timed(rep)
    expect_identical(unique(rep$tasks$pool), "read")

    # the reduce decomposition: one run, however many groups it holds
    unlink(tlog)
    cs <- .gt_rd_bands()
    invisible(collect((cs$A - cs$B) / (cs$A + cs$B), distributed = TRUE))
    expect_identical(garry_last_route(), "gd_reduce")
    rep <- suppressMessages(garry_task_report(tlog))
    .tr_timed(rep)
    expect_identical(sum(read.csv(tlog)$event == "run_start"), 1L)
  })
})

test_that("a run with no task log evaluates nothing for it", {
  withr::local_options(garry.task_log = NULL)
  tl <- garry:::.task_log_open(stop("run"), stop("pools"))
  expect_false(tl$timed)
  expect_null(tl$tick())
  expect_null(tl$line("launch", stop("key")))
})

test_that("garry_task_report splits queue from run time on start rows", {
  f <- withr::local_tempfile(fileext = ".csv")
  writeLines(c(
    "time,event,key,pool,slot,mb,store_mb,ready",
    "1.000,run_start,1x1,,,,,",
    "1.000,launch,s1_c1,comp,garry_comp_1,10,0,1.0",
    "1.000,launch,s1_c2,comp,garry_comp_1,10,0,1.0",
    "1.100,start,s1_c1,,,,,",
    "1.600,done,s1_c1,,,,,",
    "1.600,start,s1_c2,,,,,",
    "2.100,done,s1_c2,,,,,",
    "2.200,drain_end,-,,,,,",
    "2.300,host_end,-,,,,,"
  ), f)
  r <- suppressMessages(garry_task_report(f))
  t2 <- r$tasks[order(r$tasks$key), ]
  # the second task queued 0.6 s behind the first; both ran 0.5 s
  expect_equal(t2$queue_s, c(0.1, 0.6), tolerance = 1e-9)
  expect_equal(t2$run_s, c(0.5, 0.5), tolerance = 1e-9)
  expect_equal(r$stages$queue_p50, 0.35, tolerance = 1e-9)
})

test_that("garry_task_report splits harvest lag from run time on end rows", {
  f <- withr::local_tempfile(fileext = ".csv")
  writeLines(c(
    "time,event,key,pool,slot,mb,store_mb,ready",
    "1.000,run_start,1x1,,,,,",
    "1.000,launch,s1_c1,comp,garry_comp_1,10,0,1.0",
    "1.100,start,s1_c1,,,,,",
    "1.400,end,s1_c1,,,,,",
    "1.600,done,s1_c1,,,,,",
    "2.200,drain_end,-,,,,,",
    "2.300,host_end,-,,,,,"
  ), f)
  r <- suppressMessages(garry_task_report(f))
  # ran 0.3 s on the daemon; the host took 0.2 s more to harvest it
  expect_equal(r$tasks$run_s, 0.3, tolerance = 1e-9)
  expect_equal(r$tasks$harvest_s, 0.2, tolerance = 1e-9)
  expect_equal(r$stages$harvest_p50, 0.2, tolerance = 1e-9)
})

test_that("garry_task_report refuses a non-log file, classed", {
  f <- withr::local_tempfile(fileext = ".csv")
  writeLines(c("a,b", "1,2"), f)
  expect_error(garry_task_report(f), class = "garry_report_error")
  expect_error(garry_task_report(tempfile()), class = "garry_report_error")
})

test_that("garry_task_report pairs within runs, sums sweeps and survives empty logs", {
  f <- withr::local_tempfile(fileext = ".csv")
  rows <- c(
    "time,event,key,pool,slot,mb,store_mb,ready",
    "1.000,run_start,1x1,,,,,",
    "1.100,launch,s1_c1,read,1,10,0,1.0",
    "1.500,done,s1_c1,,,,,",
    "1.600,rss,101,,,100,,",
    "1.600,rss,102,,,50,,",
    "1.700,drain_end,-,,,,,",
    "1.800,host_end,-,,,,,",
    "5.000,run_start,1x2,,,,,",
    "5.100,launch,s1_c1,read,1,10,0,5.0",
    "5.200,done,s1_c1,,,,,",
    "5.300,drain_end,-,,,,,",
    "5.600,host_end,-,,,,,"
  )
  writeLines(rows, f)
  r <- suppressMessages(garry_task_report(f))
  expect_identical(nrow(r$tasks), 2L) # not the 4 a cross product gives
  expect_equal(sort(r$tasks$run_s), c(0.1, 0.4), tolerance = 1e-9)
  expect_equal(r$drain_s, 0.3, tolerance = 1e-9) # the last run's
  expect_equal(r$peak_rss_mb, 150)
  empty <- withr::local_tempfile(fileext = ".csv")
  writeLines(rows[1:2], empty)
  e <- suppressMessages(garry_task_report(empty))
  expect_identical(nrow(e$stages), 0L)
})

test_that("garry_task_report summarises role, host, cgroup, shm and budget rows", {
  f <- withr::local_tempfile(fileext = ".csv")
  writeLines(c(
    "time,event,key,pool,slot,mb,store_mb,ready",
    "1.000,run_start,1x1,,,,,",
    "1.100,launch,s1_c1,read,1,10,0,1.0",
    "1.500,done,s1_c1,,,,,",
    "2.000,rss,101,read,,100,,",
    "2.000,rss,102,read,,50,,",
    "2.000,rss,103,comp,,400,,",
    "2.000,host,99,,,700,,",
    "2.000,cgroup,-,,,2000,8000,",
    "2.000,shm,-,,,300,,",
    "2.000,budget,-,,,4000,1000,",
    "3.000,rss,101,read,,20,,",
    "3.000,rss,103,comp,,900,,",
    "3.000,host,99,,,650,,",
    "3.000,cgroup,-,,,2500,8000,",
    "3.000,shm,-,,,200,,",
    "3.000,budget,-,,,576,1000,",
    "3.100,drain_end,-,,,,,",
    "3.200,host_end,-,,,,,"
  ), f)
  r <- suppressMessages(garry_task_report(f))
  expect_equal(r$peak_rss_mb, 920)
  expect_equal(r$peak_rss_by_role[["read"]], 150)
  expect_equal(r$peak_rss_by_role[["comp"]], 900)
  expect_equal(r$peak_host_mb, 700)
  expect_equal(r$peak_cgroup_mb, 2500)
  expect_equal(r$cgroup_limit_mb, 8000)
  expect_equal(r$peak_shm_mb, 300)
  expect_equal(r$min_comp_budget_mb, 576)
})

test_that("pools record daemon roles and cap every daemon's GDAL cache", {
  withr::local_options(garry.gdal_cachemax_mb = 200)
  local_pools(1, 1)
  st <- garry:::.garry_state
  expect_setequal(names(st$pid_role), as.character(st$pool_pids))
  expect_setequal(unname(st$pid_role), c("read", "comp", "write"))
  cache_mb <- function(p) {
    mirai::mirai(
      as.numeric(format(gdalraster::get_cache_max("MB"))) / 1.048576,
      .compute = p
    )[]
  }
  for (p in c("garry_read", garry:::.comp_profiles(), "garry_write")) {
    expect_equal(cache_mb(p), 200, tolerance = 0.01)
    # read slabs and garry_gdal_config() size from the option
    expect_identical(mirai::mirai(getOption("garry.gdal_cachemax_mb"), .compute = p)[], 200)
  }
})
