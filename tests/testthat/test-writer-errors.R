# Writer-daemon failure paths: a failed sink write aborts with a classed
# garry_write_error, the post-drain wait loop exits (no hang), the
# abort-path handler awaits queued writes BEFORE the store regions
# unlink (defect hunt L3) and closes the output; and the writer_on=FALSE
# host-inline fallback stays alive and correct.

skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")

# Replace the installed .daemon_write_chunk ON THE WRITER DAEMON (tasks
# resolve .daemon_write_chunk from the daemon's namespace, so a
# host-side mock never ships). Fails from the `from`-th call on; earlier
# calls run the real writer so an output handle is genuinely open.
.we_break_writer <- function(from = 2L) {
  mirai::everywhere({
    ns <- asNamespace("garry")
    unlockBinding(".daemon_write_chunk", ns)
    .we_real <<- get(".daemon_write_chunk", envir = ns)
    .we_n <<- 0L
    assign(".daemon_write_chunk", function(...) {
      .we_n <<- .we_n + 1L
      if (.we_n >= from) stop("mock write failure (disk full)")
      .we_real(...)
    }, envir = ns)
  }, from = from, .compute = "garry_write")
}

.we_fix_writer <- function() {
  mirai::everywhere({
    ns <- asNamespace("garry")
    if (exists(".we_real", inherits = TRUE))
      assign(".daemon_write_chunk", .we_real, envir = ns)
  }, .compute = "garry_write")
}

test_that("a failed sink write aborts classed, does not hang, closes the output", {
  local_pools(2, 1)
  withr::local_options(garry.chunk_target_px = 600)   # several sink chunks
  f <- fixture_gradient_f32()
  x <- lazy_source(f) + 1
  path <- withr::local_tempfile(fileext = ".tif")

  # Cache the ABI check on clean pools first: the mock below changes
  # .daemon_write_chunk's formals, which the skew guard would (rightly)
  # refuse.
  invisible(collect(x, distributed = TRUE))
  .we_break_writer(from = 2L)
  err <- expect_error(
    suppressWarnings(write_tif(x, path, distributed = TRUE)),
    class = "garry_write_error")
  expect_match(conditionMessage(err), "mock write failure")

  # The abort-path handler closed the writer's open handle, so the partial
  # output could be removed (Windows cannot delete an open file), and the
  # SAME pools serve a clean re-run.
  expect_false(file.exists(path))
  .we_fix_writer()
  path2 <- withr::local_tempfile(fileext = ".tif")
  write_tif(x, path2, distributed = TRUE)
  want <- collect(x, distributed = FALSE)
  got <- gdal_read_window(path2, 1L, 0L, 0L, 60L, 40L)
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("the writer_on = FALSE host-inline fallback still matches the oracle", {
  local_pools(2, 1)
  # Tear down ONLY the writer: streamed writes fall back to host-inline.
  mirai::daemons(0, .compute = "garry_write")
  f <- fixture_gradient_f32()
  x <- lazy_source(f) + 1
  path <- withr::local_tempfile(fileext = ".tif")
  write_tif(x, path, distributed = TRUE)
  want <- collect(x, distributed = FALSE)
  got <- gdal_read_window(path, 1L, 0L, 0L, 60L, 40L)
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("a failed close on the writer fails the write", {
  local_pools(2, 1)
  withr::local_options(garry.chunk_target_px = 600)
  x <- lazy_source(fixture_gradient_f32()) + 1
  invisible(collect(x, distributed = TRUE)) # cache the ABI check first
  mirai::everywhere({
    ns <- asNamespace("garry")
    unlockBinding(".daemon_write_close", ns)
    .we_real_close <<- get(".daemon_write_close", envir = ns)
    assign(".daemon_write_close", function() {
      .we_real_close()
      c("/some/out.tif" = "disk full")
    }, envir = ns)
  }, .compute = "garry_write")
  # the pools are torn down at the end of the test, mock included
  path <- withr::local_tempfile(fileext = ".tif")
  expect_error(
    write_tif(x, path, distributed = TRUE),
    class = "garry_write_error"
  )
})

test_that("a failed write leaves no half-written file", {
  x <- lazy_map(lazy_source(fixture_gradient_f32()), fn = function(v) {
    stop("boom")
  }, dtype = "f32")
  path <- withr::local_tempfile(fileext = ".tif")
  expect_error(write_tif(x, path, distributed = FALSE))
  expect_false(file.exists(path))
})
