# A failed run says so the same way on every route: the classes a handler
# can rely on, the cause in GDAL's or the kernel's own words, no signed
# token anywhere the session can see it, and no output from a run that failed
# before it wrote. A run failing mid-write leaves its partial file (see
# execute_plan_mirai()) closed, for the next write to replace.

.fr_grid <- grid_spec("EPSG:3857", extent = c(0, 0, 60, 40), dims = c(x = 6L, y = 4L),
                      dtype = "f32")

# Nothing listens on this port: the read fails at once, with no network.
.fr_url <- "/vsicurl/http://127.0.0.1:9/a.tif?se=2026&sig=SECRET"
.fr_gone <- function() file.path(tempdir(), "garry-no-such-file.tif")

# With a declared grid nothing opens the source until a read does.
.fr_src <- function(path) lazy_source(path, grid = .fr_grid, block_dim = c(6L, 4L))

# `code` must fail with `class`, naming `cause`. Neither the error nor
# anything said on the way holds a token, and `out`, if given, is not there.
.fr_fails <- function(code, class, cause, out = NULL) {
  said <- character(0)
  hear <- function(cnd) said <<- c(said, conditionMessage(cnd))
  err <- expect_error(
    withCallingHandlers(code, message = hear, warning = hear),
    class = class[[1L]]
  )
  for (cl in class) {
    expect_s3_class(err, cl)
  }
  expect_match(conditionMessage(err), cause)
  expect_false(any(grepl("sig=", c(conditionMessage(err), said), fixed = TRUE)))
  if (!is.null(out)) {
    expect_false(file.exists(out))
  }
  invisible(err)
}

# Hold the placement pass to `decision` for the chain in `x`, on a reading of
# free memory that leaves it free to fuse: a failure says nothing about a
# route the plan did not take.
.fr_placed <- function(x, decision, env = parent.frame()) {
  testthat::local_mocked_bindings(.garry_ram_avail_mb = function() 1e6, .package = "garry",
                                  .env = env)
  expect_identical(unique(garry_explain_placement(x)$decision), decision)
}

# A failing read seen from each way into a pool, its kernel placed by `decision`.
.fr_on_pool <- function(x, class, cause, decision) {
  .fr_placed(x + 1, decision)
  err <- .fr_fails(collect(x + 1, distributed = TRUE), class, cause)
  expect_identical(garry_last_route(), "scheduler")
  out <- withr::local_tempfile(fileext = ".tif")
  .fr_fails(write_tif(x + 1, out, distributed = TRUE), class, cause, out)
  expect_identical(garry_last_route(), "scheduler")
  invisible(err)
}

.fr_sources <- list(
  missing = list(path = .fr_gone(), cause = "No such file or directory"),
  signed = list(path = .fr_url, cause = "connect")
)

# Two integer tiles with a gap: a read shows it, a kernel cannot hold it.
.fr_holed <- function() {
  left <- fixture_tile(1, "Int16", nx = 2L)
  right <- fixture_tile(2, "Int16", nx = 2L, gt = c(40, 10, 0, 40, 0, -10))
  g <- grid_spec("EPSG:3857", extent = c(0, 0, 60, 40), dims = c(x = 6L, y = 4L), dtype = "i16")
  lazy_source(c(left, right), grid = g)
}
.fr_hole_cause <- "holds missing values"

.fr_bomb <- function() {
  x <- lazy_source(fixture_tile(1, nx = 6L))
  lazy_map(x, fn = function(v) stop("kernel bomb"), dtype = "f32")
}
.fr_task_kernel <- c("garry_task_error", "garry_error")

# Call number `at` of `name` fails on the daemons of `prof`, and only that one.
# A kernel that stops fails its trace on the host, before any task runs, so
# this is how a kernel fails inside a task.
.fr_call_fails <- function(name, prof, at) {
  garry:::.garry_abi_check(prof) # the guard would refuse the mock below
  mirai::everywhere({
    ns <- asNamespace("garry")
    unlockBinding(name, ns)
    .fr_real <<- get(name, envir = ns)
    .fr_n <<- 0L
    assign(name, function(...) {
      .fr_n <<- .fr_n + 1L
      if (.fr_n == at) stop("kernel bomb on a daemon")
      .fr_real(...)
    }, envir = ns)
  }, name = name, at = at, .compute = prof)
}

test_that("a source that cannot open says why when it is planned", {
  withr::local_options(garry.read_retry = 0L)
  for (src in .fr_sources) {
    read <- c("garry_read_error", "garry_error")
    .fr_fails(lazy_source(src$path), read, src$cause)
    .fr_fails(lazy_dataset(src$path), read, src$cause)
    .fr_fails(extract_points(src$path, cbind(5, 35)), read, src$cause)
  }
})

test_that("a failed read fails the same way in process", {
  withr::local_options(garry.read_retry = 0L)
  for (src in .fr_sources) {
    x <- .fr_src(src$path)
    read <- c("garry_read_error", "garry_error")
    .fr_fails(collect(x, distributed = FALSE), read, src$cause)
    expect_identical(garry_last_route(), "read_only")
    .fr_fails(collect(x + 1, distributed = FALSE), read, src$cause)
    expect_identical(garry_last_route(), "single")
    out <- tempfile(fileext = ".tif")
    .fr_fails(write_tif(x + 1, out, distributed = FALSE), read, src$cause, out)
  }
})

test_that("an integer hole refuses a kernel and a file in process", {
  x <- .fr_holed()
  .fr_fails(collect(x + 1L, distributed = FALSE), c("garry_nodata_error", "garry_error"),
            .fr_hole_cause)
  out <- tempfile(fileext = ".tif")
  .fr_fails(write_tif(x, out, distributed = FALSE), c("garry_write_error", "garry_error"),
            "no `nodata` sentinel", out)
})

test_that("a kernel's own stop reaches the caller in process", {
  out <- tempfile(fileext = ".tif")
  .fr_fails(collect(.fr_bomb(), distributed = FALSE), "error", "kernel bomb")
  .fr_fails(write_tif(.fr_bomb(), out, distributed = FALSE), "error", "kernel bomb", out)
})

local({
  local_pools(2, 1)
  task_read <- c("garry_task_error", "garry_read_error", "garry_error")
  task_hole <- c("garry_task_error", "garry_nodata_error", "garry_error")

  test_that("a failed read fails the same way on the read pool", {
    withr::local_options(garry.read_retry = 0L)
    for (src in .fr_sources) {
      x <- .fr_src(src$path)
      .fr_fails(collect(x, distributed = TRUE), task_read, src$cause)
      expect_identical(garry_last_route(), "read_only")
      out <- tempfile(fileext = ".tif")
      .fr_fails(write_tif(x, out, distributed = TRUE), task_read, src$cause, out)
      expect_identical(garry_last_route(), "read_only")
    }
  })

  test_that("a failed read fails the same way under a compute stage", {
    withr::local_options(garry.read_retry = 0L, garry.placement = "rules")
    for (src in .fr_sources) {
      .fr_on_pool(.fr_src(src$path), task_read, src$cause, "comp")
    }
  })

  test_that("a failed read fails the same way under a fused kernel", {
    skip_on_os("mac") # the fused path hangs there: test-compute-on-read.R
    withr::local_options(garry.read_retry = 0L, garry.placement = "cost")
    for (src in .fr_sources) {
      .fr_on_pool(.fr_src(src$path), task_read, src$cause, "fuse")
    }
  })

  test_that("a failed fetch aborts the run, naming the object", {
    withr::local_options(garry.fetch = "force", garry.read_retry = 0L)
    dir <- withr::local_tempdir("fr")
    tiles <- file.path(dir, c("tile1.tif", "tile2.tif"))
    entries <- do.call(rbind, lapply(1:2, function(i) {
      file.copy(fixture_tile(i, nx = 6L), tiles[[i]])
      data.frame(location = tiles[[i]], slice = paste0("s", i), datetime = paste0("s", i),
                 xmin = 0, ymin = 0, xmax = 60, ymax = 40)
    }))
    idx <- file.path(dir, "fr.gti.fgb")
    gti_index_create(entries, idx, crs = "EPSG:3857")
    layers <- lapply(entries$slice, function(sl) {
      lazy_source(paste0("GTI:", idx), nodata = -9999,
                  open_options = gti_open_options(.fr_grid, filter = glue::glue("slice = '{sl}'"),
                                                  sort_field = "datetime"))
    })
    p <- plan_lazy(lazy_stack(layers))
    # the object vanishes after planning: an expired token, a deleted blob
    unlink(tiles[[2L]])
    err <- .fr_fails(execute_plan_mirai(p), task_read, "No such file or directory")
    expect_match(conditionMessage(err), "fetch failed", fixed = TRUE)
    expect_match(conditionMessage(err), "tile2.tif", fixed = TRUE)
  })

  test_that("a failed fetch of a signed URL leaves its token out", {
    withr::local_options(garry.fetch = "force", garry.read_retry = 0L, garry.placement = "rules")
    entry <- data.frame(location = .fr_url, slice = "s1", datetime = "s1",
                        xmin = 0, ymin = 0, xmax = 60, ymax = 40)
    idx <- withr::local_tempfile(fileext = ".gti.fgb")
    gti_index_create(entry, idx, crs = "EPSG:3857")
    x <- lazy_source(paste0("GTI:", idx), nodata = -9999, grid = .fr_grid, block_dim = c(6L, 4L),
                     open_options = gti_open_options(.fr_grid, filter = "slice = 's1'",
                                                     sort_field = "datetime"))
    err <- .fr_fails(collect(x + 1, distributed = TRUE), task_read, "connect")
    expect_match(conditionMessage(err), "fetch failed", fixed = TRUE)
  })

  test_that("an integer hole fails on the compute pool, and passes a read", {
    withr::local_options(garry.placement = "rules")
    x <- .fr_holed()
    want <- matrix(c(1, 1, NaN, NaN, 2, 2), 4L, 6L, byrow = TRUE)
    expect_plan(x, want, "i16", legs = list(.read_pool), file = FALSE)
    .fr_on_pool(x, task_hole, .fr_hole_cause, "comp")
    # the read pool prepares the write, and has no sentinel to hand it
    out <- tempfile(fileext = ".tif")
    .fr_fails(write_tif(x, out, distributed = TRUE),
              c("garry_task_error", "garry_write_error", "garry_error"),
              "no `nodata` sentinel", out)
    expect_identical(garry_last_route(), "read_only")
    # the same target takes a good write on the same pool
    write_tif(lazy_source(fixture_tile(1, nx = 6L)), out, distributed = TRUE)
    expect_identical(garry_last_route(), "read_only")
    expect_true(file.exists(out))
  })

  test_that("an integer hole fails under a fused kernel", {
    skip_on_os("mac")
    withr::local_options(garry.placement = "cost")
    .fr_on_pool(.fr_holed(), task_hole, .fr_hole_cause, "fuse")
  })

  # The stage and the fused read each trace their kernel on the host.
  bomb <- function(decision) {
    .fr_placed(.fr_bomb(), decision)
    out <- tempfile(fileext = ".tif")
    .fr_fails(collect(.fr_bomb(), distributed = TRUE), .fr_task_kernel, "kernel bomb")
    .fr_fails(write_tif(.fr_bomb(), out, distributed = TRUE), .fr_task_kernel, "kernel bomb", out)
  }

  test_that("a compute stage's kernel that fails its trace is a task failure", {
    withr::local_options(garry.placement = "rules")
    bomb("comp")
  })

  test_that("a fused kernel that fails its trace is a task failure", {
    skip_on_os("mac")
    withr::local_options(garry.placement = "cost")
    bomb("fuse")
  })

  test_that("the pools go on after every failure above", {
    x <- lazy_source(fixture_tile(1, nx = 6L)) + 1
    expect_plan(x, matrix(2, 4L, 6L), "f32", legs = list(.comp), file = FALSE)
  })
})

local({
  # one daemon of each, so that a run's second task is a daemon's second call
  local_pools(1, 1)
  x <- lazy_source(fixture_tile(1, nx = 6L)) + 1
  want <- matrix(2, 4L, 6L)

  test_that("a task failing mid-write fails the run, and the target stays writable", {
    withr::local_options(garry.placement = "rules", garry.chunk_target_px = 4)
    .fr_placed(x, "comp")
    expect_gt(.plan_chunks(x), 1L)
    .fr_call_fails(".daemon_run_compute_shm", garry:::.comp_profiles(), 2L)
    out <- withr::local_tempfile(fileext = ".tif")
    err <- .fr_fails(write_tif(x, out, distributed = TRUE), .fr_task_kernel,
                     "kernel bomb on a daemon")
    expect_true(nzchar(err$task))
    write_tif(x, out, distributed = TRUE)
    .expect_cells(.read_cube(out), want)
  })

  test_that("a kernel failing on a fused read fails the run as a task", {
    skip_on_os("mac")
    withr::local_options(garry.placement = "cost")
    .fr_placed(x, "fuse")
    .fr_call_fails(".apply_fuse", "garry_read", 1L)
    err <- .fr_fails(collect(x, distributed = TRUE), .fr_task_kernel, "kernel bomb on a daemon")
    expect_true(nzchar(err$task))
    .expect_cells(unclass(collect(x, distributed = TRUE)), want)
  })
})
