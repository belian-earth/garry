# Scheduler failure modes: a failing kernel and a dying daemon both
# abort with a classed garry_task_error (task key, stage, pool fields),
# the on.exit chain leaves /dev/shm clean, and the pools stay (or can be
# made) serviceable afterwards.

skip_if_not_installed("anvl")
skip_if_not_installed("mirai")
skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")
skip_on_os(c("windows", "mac"))   # /dev/shm scan

.sf_shm <- function() sort(list.files("/dev/shm"))

# The shm-clear handlers dispatch via everywhere() without awaiting, so
# give the daemons a moment before asserting the store is clean.
.sf_expect_shm_restored <- function(before, timeout = 10) {
  t0 <- Sys.time()
  repeat {
    extra <- setdiff(.sf_shm(), before)
    if (!length(extra)) break
    if (as.numeric(Sys.time() - t0, units = "secs") > timeout) break
    Sys.sleep(0.2)
  }
  expect_identical(setdiff(.sf_shm(), before), character(0))
}

test_that("a failing kernel aborts classed and leaves a clean store", {
  garry_daemons(2, 1, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  withr::local_options(garry.chunk_target_px = 600)
  f <- fixture_gradient_f32()
  before <- .sf_shm()
  bomb <- lazy_map(lazy_source(f), fn = function(v) stop("kernel bomb"))
  err <- expect_error(
    suppressWarnings(collect(bomb, distributed = TRUE)),
    class = "garry_task_error")
  expect_match(conditionMessage(err), "kernel bomb")
  expect_true(is.character(err$task) && nzchar(err$task))
  .sf_expect_shm_restored(before)
  # The SAME pools serve a clean run afterwards.
  got <- collect(lazy_source(f) + 1, distributed = TRUE)
  want <- collect(lazy_source(f) + 1, distributed = FALSE)
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("a daemon dying mid-drain aborts classed; pools are rebuildable", {
  garry_daemons(2, 2, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  withr::local_options(garry.placement = "rules",   # sink tasks stay on comp pool
                       garry.chunk_target_px = 600)
  f <- fixture_gradient_f32()
  # Cache the ABI check on clean pools first (the mock below changes the
  # daemon-side formals, which the skew guard would rightly refuse).
  invisible(collect(lazy_source(f) + 1, distributed = TRUE))
  # Deterministic death: the compute task body kills its own daemon.
  mirai::everywhere({
    ns <- asNamespace("garry")
    unlockBinding(".daemon_run_compute_shm", ns)
    assign(".daemon_run_compute_shm", function(...) {
      tools::pskill(Sys.getpid(), 9L)
      Sys.sleep(5)
    }, envir = ns)
  }, .compute = "garry_compute")
  before <- .sf_shm()
  err <- expect_error(
    suppressWarnings(collect(lazy_source(f) + 1, distributed = TRUE)),
    class = "garry_task_error")
  .sf_expect_shm_restored(before)
  # Rebuild the pools; the host session is still serviceable.
  garry_daemons(0, 0, gdal_config = FALSE)
  garry_daemons(2, 1, gdal_config = FALSE)
  got <- collect(lazy_source(f) + 1, distributed = TRUE)
  want <- collect(lazy_source(f) + 1, distributed = FALSE)
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
})
