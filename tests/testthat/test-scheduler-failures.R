# Scheduler failure modes: a failing kernel and a dying daemon both
# abort with a classed garry_task_error (task key, stage, pool fields),
# the on.exit chain leaves /dev/shm clean, and the pools stay (or can be
# made) serviceable afterwards.

skip_on_os(c("windows", "mac"))   # /dev/shm scan

# mori names a region after its creating process (mori_<pid hex>_<n>),
# and /dev/shm is machine-wide: under parallel testthat the other
# workers' daemons populate it concurrently, so the scan is confined
# to regions of THIS test's processes (host session plus every pool
# daemon). Capture the pid set once per test, before anything dies.
.sf_pids <- function() {
  pools <- c("garry_read", garry:::.comp_profiles(), "garry_write")
  c(Sys.getpid(), unlist(lapply(pools, garry:::.garry_pool_pids)))
}
.sf_shm <- function(pids) {
  all <- list.files("/dev/shm")
  own <- paste0("^mori_(", paste(sprintf("%x", pids), collapse = "|"), ")_")
  sort(all[grepl(own, all)])
}

# A run waits for its shm clear before it returns, failed or not, on every
# pool it ran a task on that still has all its daemons. The poll is a
# bound, not a delay: it returns as soon as the store is clean.
.sf_expect_shm_restored <- function(before, pids, timeout = 30) {
  t0 <- Sys.time()
  repeat {
    extra <- setdiff(.sf_shm(pids), before)
    if (!length(extra)) break
    if (as.numeric(Sys.time() - t0, units = "secs") > timeout) break
    Sys.sleep(0.2)
  }
  expect_identical(setdiff(.sf_shm(pids), before), character(0))
}

test_that("a failing kernel aborts classed and leaves a clean store", {
  local_pools(2, 1)
  # rules placement keeps the kernel on the compute pool, where it can fail
  withr::local_options(garry.chunk_target_px = 600, garry.placement = "rules")
  f <- fixture_gradient_f32()
  pids <- .sf_pids()
  before <- .sf_shm(pids)
  # traced on the host, a kernel fails before any task launches
  bomb <- lazy_map(lazy_source(f), fn = function(v) stop("kernel bomb"), dtype = "f32")
  err <- expect_error(
    suppressWarnings(collect(bomb, distributed = TRUE)),
    class = "garry_task_error")
  expect_match(conditionMessage(err), "kernel bomb")
  expect_true(is.character(err$task) && nzchar(err$task))
  # on a daemon it fails with regions held: its second task fails, once
  x <- lazy_source(f) + 1
  prof <- garry:::.comp_profiles()[[1L]]
  garry:::.garry_abi_check(prof) # the guard would refuse the mock below
  mirai::everywhere({
    ns <- asNamespace("garry")
    unlockBinding(".daemon_run_compute_shm", ns)
    .sf_real <<- get(".daemon_run_compute_shm", envir = ns)
    .sf_n <<- 0L
    assign(".daemon_run_compute_shm", function(...) {
      .sf_n <<- .sf_n + 1L
      if (.sf_n == 2L) stop("kernel bomb on a daemon")
      .sf_real(...)
    }, envir = ns)
  }, .compute = prof)
  err <- expect_error(
    suppressWarnings(collect(x, distributed = TRUE)),
    class = "garry_task_error")
  expect_match(conditionMessage(err), "kernel bomb on a daemon")
  expect_true(is.character(err$task) && nzchar(err$task))
  .sf_expect_shm_restored(before, pids)
  # The SAME pools serve a clean run afterwards.
  got <- collect(x, distributed = TRUE)
  expect_equal(unclass(got), .fixture_values(60, 40) + 1, tolerance = 0, ignore_attr = TRUE)
})

test_that("a daemon dying mid-drain aborts classed; pools are rebuildable", {
  local_pools(1, 1)
  withr::local_options(garry.placement = "rules",   # sink tasks stay on comp pool
                       garry.chunk_target_px = 600)
  x <- lazy_source(fixture_gradient_f32()) + 1
  prof <- garry:::.comp_profiles()
  garry:::.garry_abi_check(prof) # the guard would refuse the mock below
  # Deterministic death: the compute task body kills its own daemon.
  mirai::everywhere({
    ns <- asNamespace("garry")
    unlockBinding(".daemon_run_compute_shm", ns)
    assign(".daemon_run_compute_shm", function(...) {
      tools::pskill(Sys.getpid(), 9L)
      Sys.sleep(5)
    }, envir = ns)
  }, .compute = prof)
  pids <- .sf_pids()
  before <- .sf_shm(pids)
  err <- expect_error(
    suppressWarnings(collect(x, distributed = TRUE)),
    class = "garry_task_error")
  .sf_expect_shm_restored(before, pids)
  # Rebuild the pools; the host session is still serviceable.
  garry_daemons(1, 1, gdal_config = FALSE)
  got <- collect(x, distributed = TRUE)
  expect_equal(unclass(got), .fixture_values(60, 40) + 1, tolerance = 0, ignore_attr = TRUE)
})

test_that("a failed read-only write leaves no region on the readers", {
  local_pools(3, 1)
  withr::local_options(garry.chunk_target_px = 400, garry.read_target_px = 400)
  testthat::local_mocked_bindings(.copy_args = function(...) NULL, .package = "garry") # the pool write
  f <- fixture_gradient_f32()
  pids <- .sf_pids()
  before <- .sf_shm(pids)
  garry:::.garry_abi_check("garry_read") # the guard would refuse the mock below
  # the first read fails, and the rest are still running when the host gives up
  mirai::everywhere({
    ns <- asNamespace("garry")
    unlockBinding(".daemon_read_for_write", ns)
    .sf_real <<- get(".daemon_read_for_write", envir = ns)
    assign(".daemon_read_for_write", function(a, cg, core, dt, nd, reg) {
      if (endsWith(reg, "_1")) stop("read bomb on a daemon")
      Sys.sleep(0.5)
      .sf_real(a, cg, core, dt, nd, reg)
    }, envir = ns)
  }, .compute = "garry_read")
  err <- expect_error(
    write_tif(lazy_source(f), withr::local_tempfile(fileext = ".tif"), distributed = TRUE),
    class = "garry_task_error"
  )
  expect_match(conditionMessage(err), "read bomb on a daemon")
  # a retry at once, with those reads still running, keeps its own regions:
  # the clear is queued ahead of it
  mirai::everywhere(
    assign(".daemon_read_for_write", .sf_real, envir = asNamespace("garry")),
    .compute = "garry_read"
  )
  out <- withr::local_tempfile(fileext = ".tif")
  write_tif(lazy_source(f), out, distributed = TRUE)
  expect_equal(
    gdal_read_window(out, 1L, 0L, 0L, 60L, 40L),
    gdal_read_window(f, 1L, 0L, 0L, 60L, 40L)
  )
  # a broadcast queues behind them too: every region they pinned is in
  left <- garry:::.pool_broadcast(
    quote(ls(asNamespace("garry")$.daemon_shm, all.names = TRUE)),
    profiles = "garry_read"
  )
  expect_length(unlist(left), 0L)
  .sf_expect_shm_restored(before, pids)
})

test_that("a deadlock names what is blocked and what is holding it", {
  err <- expect_error(
    garry:::.scheduler_deadlock(3L, "s4_c2", "comp", 512, 400, 1024),
    class = "garry_scheduler_error"
  )
  msg <- conditionMessage(err)
  for (want in c("3 tasks", "s4_c2", "comp", "512", "400", "1024", "garry.read_budget_mb")) {
    expect_match(msg, want, fixed = TRUE)
  }
})
