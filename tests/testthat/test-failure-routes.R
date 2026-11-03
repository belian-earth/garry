# A failed run says so the same way on every route: the classes a handler
# can rely on, the cause in GDAL's or the kernel's own words, no signed
# token anywhere the session can see it, and every target as it was, whether
# it failed before it wrote or part way through (.collect_write()).

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

# GDAL 3.13 names the refused connection; 3.11 says only that the path does not exist.
.fr_refused <- "connect|does not exist"

.fr_sources <- list(
  missing = list(path = .fr_gone(), cause = "No such file or directory"),
  signed = list(path = .fr_url, cause = .fr_refused)
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

# What materialise() writes. A list and a dataset's slices write `first`
# before `last`.
.fr_mat_forms <- function(first, last) {
  slices <- stats::setNames(list(first, last), c("2024-01-05", "2024-01-20"))
  list(raster = last, list = list(a = first, b = last), slices = as_dataset(list(B = slices)))
}

# Chunk `at` of the write in `code` fails on the host, as on a full disk.
# Returns the names of the files the run had built under `dir` by then.
.fr_chunk_fails <- function(at, dir, code) {
  real <- garry:::.exec_write_chunk
  landed <- 0L
  started <- character(0)
  testthat::local_mocked_bindings(
    .exec_write_chunk = function(...) {
      landed <<- landed + 1L
      if (landed == at) {
        started <<- basename(list.files(dir, recursive = TRUE, all.files = TRUE))
        stop("disk full")
      }
      real(...)
    },
    .package = "garry"
  )
  expect_error(code, "disk full")
  started
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

test_that("a materialise failing mid-write in process leaves no target", {
  for (type in c("Float32", "Int16")) {
    one <- lazy_source(fixture_tile(1, type, nx = 6L))
    forms <- .fr_mat_forms(one + 1L, one * 2L)
    for (form in names(forms)) {
      x <- forms[[form]]
      dir <- withr::local_tempdir()
      info <- paste(type, form)
      # each file of the earlier sinks and of the sink that fails has started
      sinks <- if (form == "raster") 1L else 2L
      started <- .fr_chunk_fails(sinks, dir, materialise(x, dir, name = "m", distributed = FALSE))
      expect_length(started, sinks * if (type == "Float32") 2L else 1L)
      expect_identical(list.files(dir), character(0), info = info)
      # nothing at the target refuses the same call
      materialise(x, dir, name = "m", distributed = FALSE)
      expect_gt(length(list.files(dir)), 0L)
    }
  }
})

test_that("list and grouped writes leave no sink that finished before a failure", {
  one <- lazy_source(fixture_tile(1, nx = 6L))
  dir <- withr::local_tempdir()
  started <- .fr_chunk_fails(2L, dir, write_tif(list(a = one + 1, b = one * 2), dir, distributed = FALSE))
  expect_setequal(started, c("a.tif", "b.tif"))
  expect_identical(list.files(dir), character(0))
  groups <- group_by_time(.fr_mat_forms(one + 1, one * 2)$slices, "day")
  started <- .fr_chunk_fails(2L, dir, write_tif(groups, file.path(dir, "c-{group}.tif"), distributed = FALSE))
  expect_setequal(started, c("c-2024-01-05.tif", "c-2024-01-20.tif"))
  expect_identical(list.files(dir), character(0))
})

test_that("a failed write leaves a file at a target", {
  one <- lazy_source(fixture_tile(1, nx = 6L))
  dir <- withr::local_tempdir()
  writeLines("keep", file.path(dir, "b.tif"))
  .fr_chunk_fails(1L, dir, write_tif(list(a = one + 1, b = one * 2), dir, distributed = FALSE))
  expect_identical(list.files(dir), "b.tif")
  expect_identical(readLines(file.path(dir, "b.tif")), "keep")
  # refused before its first byte, a write reaches none of them
  writeLines("keep", file.path(dir, "a.tif"))
  bytes <- function() lazy_source(fixture_tile(1, "Byte", nx = 6L))
  expect_error(write_tif(list(a = bytes(), b = bytes()), dir, nodata = -1, distributed = FALSE),
               class = "garry_write_error")
  expect_identical(readLines(file.path(dir, "a.tif")), "keep")
  expect_identical(readLines(file.path(dir, "b.tif")), "keep")
})

# What a directory holds, by content.
.fr_held <- function(dir) tools::md5sum(sort(list.files(dir, full.names = TRUE)))

test_that("a materialise refused before its first byte keeps the checkpoint", {
  for (type in c("Float32", "Int16")) {
    one <- lazy_source(fixture_tile(1, type, nx = 6L))
    forms <- .fr_mat_forms(one + 1L, one * 2L)
    for (form in names(forms)) {
      dir <- withr::local_tempdir()
      materialise(forms[[form]], dir, name = "m", distributed = FALSE)
      held <- .fr_held(dir)
      expect_gt(length(held), 0L)
      expect_error(materialise(forms[[form]], dir, name = "m", overwrite = TRUE, distributed = TRUE),
                   "no garry daemon pools")
      expect_identical(.fr_held(dir), held, info = paste(type, form))
    }
  }
  # a sentinel its band cannot hold
  one <- lazy_source(fixture_tile(1, "Int16", nx = 6L))
  dir <- withr::local_tempdir()
  materialise(one + 1L, dir, name = "m", distributed = FALSE)
  held <- .fr_held(dir)
  expect_error(materialise(one + 1L, dir, name = "m", nodata = 1e9, overwrite = TRUE, distributed = FALSE),
               class = "garry_write_error")
  expect_identical(.fr_held(dir), held)
})

test_that("a materialise whose read fails on the host keeps the checkpoint", {
  withr::local_options(garry.read_retry = 0L)
  for (dtype in c("f32", "i16")) {
    type <- c(f32 = "Float32", i16 = "Int16")[[dtype]]
    good <- lazy_source(fixture_tile(1, type, nx = 6L))
    bad <- lazy_source(.fr_gone(), grid = garry:::.grid_retype(.fr_grid, dtype),
                       block_dim = c(6L, 4L))
    forms <- .fr_mat_forms(good + 1L, bad + 1L)
    fine <- .fr_mat_forms(good + 1L, good * 2L)
    for (form in names(forms)) {
      dir <- withr::local_tempdir()
      materialise(fine[[form]], dir, name = "m", distributed = FALSE)
      held <- .fr_held(dir)
      .fr_fails(materialise(forms[[form]], dir, name = "m", overwrite = TRUE, distributed = FALSE),
                c("garry_read_error", "garry_error"), .fr_sources$missing$cause)
      expect_identical(.fr_held(dir), held, info = paste(dtype, form))
    }
  }
})

test_that("an overwrite that fails between a cube's two files keeps the old pair", {
  one <- lazy_source(fixture_tile(1, nx = 6L)) + 1
  dir <- withr::local_tempdir()
  materialise(one, dir, name = "m", distributed = FALSE)
  held <- .fr_held(dir)
  local_mocked_bindings(.raw_bsq_vrt_xml = function(...) stop("disk full"))
  expect_error(materialise(one, dir, name = "m", overwrite = TRUE, distributed = FALSE), "disk full")
  expect_identical(.fr_held(dir), held)
})

test_that("a failed write leaves a file the run did not create", {
  # the kernel stands in for another process, writing while the run has yet
  # to reach its target
  one <- lazy_source(fixture_tile(1, nx = 6L))
  bomb <- function(out) {
    lazy_map(one, dtype = "f32", fn = function(v) {
      writeLines("other", out)
      stop("kernel bomb")
    })
  }
  for (there in c(TRUE, FALSE)) {
    dir <- withr::local_tempdir()
    out <- file.path(dir, "o.tif")
    if (there) writeLines("first", out)
    expect_error(write_tif(bomb(out), out, distributed = FALSE), "kernel bomb")
    expect_identical(readLines(out), "other", info = there)
    out <- file.path(dir, "m.vrt")
    if (there) writeLines("first", out)
    expect_error(materialise(bomb(out), dir, name = "m", overwrite = TRUE, distributed = FALSE),
                 "kernel bomb")
    expect_identical(readLines(out), "other", info = there)
  }
})

test_that("a COG finalise failing part way replaces no target", {
  one <- lazy_source(fixture_tile(1, nx = 6L))
  real <- gdal_translate_file
  n <- 0L
  local_mocked_bindings(gdal_translate_file = function(...) {
    n <<- n + 1L
    if (n == 2L) stop("disk full")
    real(...)
  })
  dir <- withr::local_tempdir()
  expect_error(write_tif(list(a = one + 1, b = one * 2), dir, cog = TRUE, distributed = FALSE),
               "disk full")
  expect_identical(n, 2L)
  expect_identical(list.files(dir), character(0))
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
    err <- .fr_fails(collect(x + 1, distributed = TRUE), task_read, .fr_refused)
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

  # A pool opens its outputs before the first task runs, so a read failing at
  # once has still started every file in the temporary directory.
  test_that("a materialise failing on the pools leaves no target", {
    withr::local_options(garry.read_retry = 0L, garry.placement = "rules")
    for (dtype in c("f32", "i16")) {
      type <- c(f32 = "Float32", i16 = "Int16")[[dtype]]
      good <- lazy_source(fixture_tile(1, type, nx = 6L))
      bad <- lazy_source(.fr_gone(), grid = garry:::.grid_retype(.fr_grid, dtype),
                         block_dim = c(6L, 4L))
      forms <- .fr_mat_forms(good + 1L, bad + 1L)
      fine <- .fr_mat_forms(good + 1L, good * 2L)
      for (form in names(forms)) {
        dir <- withr::local_tempdir()
        info <- paste(dtype, form)
        .fr_fails(materialise(forms[[form]], dir, name = "m", distributed = TRUE),
                  task_read, .fr_sources$missing$cause)
        expect_identical(garry_last_route(), "scheduler", info = info)
        expect_identical(list.files(dir), character(0), info = info)
        # nothing at the target refuses the next call
        materialise(fine[[form]], dir, name = "m", distributed = TRUE)
        expect_gt(length(list.files(dir)), 0L)
      }
    }
    groups <- group_by_time(forms$slices, "day")
    dir <- withr::local_tempdir()
    .fr_fails(write_tif(groups, file.path(dir, "c-{group}.tif"), distributed = TRUE),
              task_read, .fr_sources$missing$cause)
    expect_identical(list.files(dir), character(0))
  })

  test_that("a materialise failing on the read pool leaves no target", {
    withr::local_options(garry.read_retry = 0L)
    dir <- withr::local_tempdir()
    .fr_fails(materialise(.fr_src(.fr_gone()), dir, name = "m", distributed = TRUE),
              task_read, .fr_sources$missing$cause)
    expect_identical(garry_last_route(), "read_only")
    expect_identical(list.files(dir), character(0))
  })

  test_that("a materialise failing under a fused kernel leaves no target", {
    skip_on_os("mac")
    withr::local_options(garry.read_retry = 0L, garry.placement = "cost")
    x <- .fr_src(.fr_gone())
    .fr_placed(x + 1, "fuse")
    dir <- withr::local_tempdir()
    .fr_fails(materialise(x + 1, dir, name = "m", distributed = TRUE),
              task_read, .fr_sources$missing$cause)
    expect_identical(list.files(dir), character(0))
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
                     "kernel bomb on a daemon", out)
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

local({
  local_pools(1, 1)

  test_that("a task failing mid-materialise leaves nothing of the first chunks", {
    withr::local_options(garry.placement = "rules", garry.chunk_target_px = 4)
    one <- lazy_source(fixture_tile(1, nx = 6L))
    x <- list(a = one + 1, b = one * 2)
    expect_gt(.plan_chunks(x), 1L)
    .fr_call_fails(".daemon_run_compute_shm", garry:::.comp_profiles(), 2L)
    dir <- withr::local_tempdir()
    .fr_fails(materialise(x, dir, name = "m", distributed = TRUE), .fr_task_kernel,
              "kernel bomb on a daemon")
    expect_identical(list.files(dir), character(0))
    back <- materialise(x, dir, name = "m", distributed = TRUE)
    .expect_cells(unclass(collect(back$a, distributed = FALSE)), matrix(2, 4L, 6L))
    .expect_cells(unclass(collect(back$b, distributed = FALSE)), matrix(2, 4L, 6L))
  })
})
