# Writer-daemon failure paths: a failed sink write aborts with a classed
# garry_write_error, the post-drain wait loop exits (no hang), the
# abort-path handler awaits queued writes BEFORE the store regions
# unlink (defect hunt L3) and closes the output; and a dead writer fails
# the write, which never moves to the host.

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

test_that("a dead writer fails a write, and only a write", {
  local_pools(2, 1)
  mirai::daemons(0, .compute = "garry_write")
  f <- fixture_gradient_f32()
  x <- lazy_source(f) + 1
  path <- withr::local_tempfile(fileext = ".tif")
  expect_error(write_tif(x, path, distributed = TRUE), class = "garry_pool_error")
  expect_error(write_tif(lazy_source(f), path, distributed = TRUE), class = "garry_pool_error")
  expect_false(file.exists(path))
  want <- collect(x, distributed = FALSE)
  expect_equal(collect(x, distributed = TRUE), want, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("a close that fails or dies on the writer fails the write", {
  skip_on_os("windows") # tools::pskill semantics
  local_pools(2, 1)
  withr::local_options(garry.chunk_target_px = 600)
  x <- lazy_source(fixture_gradient_f32()) + 1
  invisible(collect(x, distributed = TRUE)) # cache the ABI check first
  # the pools are torn down at the end of the test, mocks included
  mock_close <- function(fn) {
    mirai::everywhere({
      ns <- asNamespace("garry")
      unlockBinding(".daemon_write_close", ns)
      assign(".daemon_write_close", fn, envir = ns)
    }, fn = fn, .compute = "garry_write")
  }
  path <- withr::local_tempfile(fileext = ".tif")

  mock_close(function() c("/some/out.tif" = "disk full"))
  err <- expect_error(write_tif(x, path, distributed = TRUE), class = "garry_write_error")
  expect_match(conditionMessage(err), "disk full", fixed = TRUE)
  expect_match(conditionMessage(err), "/some/out.tif", fixed = TRUE)

  mock_close(function() stop("close blew up"))
  err <- expect_error(write_tif(x, path, distributed = TRUE), class = "garry_write_error")
  expect_match(conditionMessage(err), "close blew up", fixed = TRUE)

  mock_close(function() tools::pskill(Sys.getpid(), tools::SIGKILL))
  expect_error(write_tif(x, path, distributed = TRUE), "daemon")
  expect_false(file.exists(path))
})

# /dev/full takes any file open and fails every write with ENOSPC at the
# kernel, as a full disk does: a real GDAL failure, in a few milliseconds.
.we_full_target <- function(env = parent.frame()) {
  skip_if_not(file.exists("/dev/full"), "needs /dev/full")
  p <- withr::local_tempfile(fileext = ".tif", .local_envir = env)
  file.symlink("/dev/full", p)
  p
}

.we_grid <- grid_spec("EPSG:3857", extent = c(0, 0, 160, 160),
                      dims = c(16L, 16L), dtype = "f32")

test_that("a full disk fails a host write", {
  p <- .we_full_target()
  x <- lazy_source(fixture_gradient_f32()) + 1
  err <- expect_error(
    suppressMessages(write_tif(x, p, distributed = FALSE)),
    class = "garry_write_error"
  )
  expect_match(conditionMessage(err), basename(p), fixed = TRUE)
  expect_match(conditionMessage(err), "TIFF", fixed = TRUE)
})

test_that("a close that never reached the disk is reported by the writer", {
  p <- .we_full_target()
  assign(p, gdal_create_output(p, .we_grid), envir = .daemon_ds)
  failed <- suppressMessages(.daemon_write_close())
  expect_named(failed, p)
  expect_match(failed[[p]], "TIFF", fixed = TRUE)
})

test_that("a write GDAL reports failed stops the write, naming the file", {
  p <- .we_full_target()
  ds <- gdal_create_output(p, .we_grid)
  withr::defer(try(ds$close(), silent = TRUE))
  err <- expect_error(
    suppressMessages(gdal_write_window(ds, 0L, 0L, matrix(runif(256), 16L, 16L), "f32")),
    class = "garry_write_error"
  )
  expect_match(conditionMessage(err), basename(p), fixed = TRUE)
})

test_that("a closed output with data past its end is incomplete", {
  p <- withr::local_tempfile(fileext = ".tif")
  ds <- gdal_create_output(p, .we_grid)
  gdal_write_window(ds, 0L, 0L, matrix(runif(256), 16L, 16L), "f32")
  gdal_close_output(ds, p)
  expect_null(.gtiff_incomplete(p))
  n <- file.size(p)
  writeBin(readBin(p, "raw", n)[seq_len(n - 40L)], p)
  expect_match(.gtiff_incomplete(p), "cannot be read|runs to byte")
})

test_that("the end of a GTiff's data reads in every layout", {
  tiled <- c("TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16") # one tile: inline values
  layouts <- list(
    "COMPRESS=DEFLATE",
    "COMPRESS=NONE",
    c("BIGTIFF=YES", "COMPRESS=DEFLATE"),
    "ENDIAN=BIG",
    c("BIGTIFF=YES", "ENDIAN=BIG"),
    "BLOCKYSIZE=4",
    tiled
  )
  for (o in layouts) {
    p <- withr::local_tempfile(fileext = ".tif")
    ds <- gdal_create_output(p, .we_grid, options = o)
    gdal_write_window(ds, 0L, 0L, matrix(runif(256), 16L, 16L), "f32")
    ds$close()
    end <- .gtiff_data_end(p)
    expect_gt(end, 100)
    expect_lte(end, file.size(p))
    expect_null(.gtiff_incomplete(p))
  }
})

test_that("a sparse GTiff is whole", {
  p <- withr::local_tempfile(fileext = ".tif")
  ds <- gdal_create_output(p, .we_grid, options = "SPARSE_OK=TRUE")
  expect_identical(gdal_close_output(ds, p), p)
})

test_that("a raw cube closes without a TIFF check", {
  p <- withr::local_tempfile(fileext = ".vrt")
  withr::defer(unlink(sub("vrt$", "bin", p)))
  ds <- gdal_create_output(p, .we_grid)
  gdal_write_window(ds, 0L, 0L, matrix(runif(256), 16L, 16L), "f32")
  expect_identical(gdal_close_output(ds, p), p)
})

test_that("a failed COG finalise names the cause", {
  testthat::local_mocked_bindings(
    gdal_translate_file = function(...) stop("translate blew up"),
    .package = "garry"
  )
  x <- lazy_source(fixture_gradient_f32()) + 1
  p <- withr::local_tempfile(fileext = ".tif")
  err <- expect_error(write_tif(x, p, cog = TRUE, distributed = FALSE), class = "garry_write_error")
  expect_match(conditionMessage(err), "translate blew up", fixed = TRUE)
})

test_that("a failed write leaves no half-written file", {
  x <- lazy_map(lazy_source(fixture_gradient_f32()), fn = function(v) {
    stop("boom")
  }, dtype = "f32")
  path <- withr::local_tempfile(fileext = ".tif")
  expect_error(write_tif(x, path, distributed = FALSE))
  expect_false(file.exists(path))
})
