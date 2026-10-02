# garry_task_report(): the task-log CSV schema is locked
# (time,event,key,pool,slot,mb,store_mb,ready) and the report turns it
# from a developer trace into an operator tool: complete launch/done
# pairs, per-stage durations and queue waits, max concurrency, drain vs
# host tail.

skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")

test_that("garry_task_report summarises a distributed run's log", {
  local_pools(2, 1)
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
  expect_false(is.na(rep$drain_s))
  expect_false(is.na(rep$host_tail_s))
  # run and wait times are well-formed (ready <= launch <= done)
  expect_true(all(rep$tasks$run_s >= 0))
  expect_true(all(is.finite(rep$tasks$wait_s)))
  expect_true(all(rep$tasks$wait_s >= -0.001))
  # per-stage summary covers every task
  expect_identical(sum(rep$stages$n), nrow(rep$tasks))
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
