# Scheduler failure modes: a failing kernel and a dying daemon both
# abort with a classed garry_task_error (task key, stage, pool fields),
# the on.exit chain leaves /dev/shm clean, and the pools stay (or can be
# made) serviceable afterwards.

skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")
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

# The shm-clear handlers dispatch via everywhere() without awaiting, so
# give the daemons a moment before asserting the store is clean.
.sf_expect_shm_restored <- function(before, pids, timeout = 10) {
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
  withr::local_options(garry.chunk_target_px = 600)
  f <- fixture_gradient_f32()
  pids <- .sf_pids()
  before <- .sf_shm(pids)
  bomb <- lazy_map(lazy_source(f), fn = function(v) stop("kernel bomb"))
  err <- expect_error(
    suppressWarnings(collect(bomb, distributed = TRUE)),
    class = "garry_task_error")
  expect_match(conditionMessage(err), "kernel bomb")
  expect_true(is.character(err$task) && nzchar(err$task))
  .sf_expect_shm_restored(before, pids)
  # The SAME pools serve a clean run afterwards.
  got <- collect(lazy_source(f) + 1, distributed = TRUE)
  want <- collect(lazy_source(f) + 1, distributed = FALSE)
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("a daemon dying mid-drain aborts classed; pools are rebuildable", {
  local_pools(2, 2)
  withr::local_options(garry.placement = "rules",   # sink tasks stay on comp pool
                       garry.chunk_target_px = 600)
  f <- fixture_gradient_f32()
  # Cache the ABI check on clean pools first (the mock below changes the
  # daemon-side formals, which the skew guard would rightly refuse).
  invisible(collect(lazy_source(f) + 1, distributed = TRUE))
  # Deterministic death: the compute task body kills its own daemon.
  for (p in garry:::.comp_profiles())
    mirai::everywhere({
      ns <- asNamespace("garry")
      unlockBinding(".daemon_run_compute_shm", ns)
      assign(".daemon_run_compute_shm", function(...) {
        tools::pskill(Sys.getpid(), 9L)
        Sys.sleep(5)
      }, envir = ns)
    }, .compute = p)
  pids <- .sf_pids()
  before <- .sf_shm(pids)
  err <- expect_error(
    suppressWarnings(collect(lazy_source(f) + 1, distributed = TRUE)),
    class = "garry_task_error")
  .sf_expect_shm_restored(before, pids)
  # Rebuild the pools; the host session is still serviceable.
  garry_daemons(0, 0, gdal_config = FALSE)
  garry_daemons(2, 1, gdal_config = FALSE)
  got <- collect(lazy_source(f) + 1, distributed = TRUE)
  want <- collect(lazy_source(f) + 1, distributed = FALSE)
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
})
