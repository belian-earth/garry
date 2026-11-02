# On the CPU a task's reads go into C memory that its input arrays adopt. XLA reads
# those bytes in place and the task frees them with no gc. Every test here runs the
# real task bodies and kernels. A handle the test still holds cannot be collected, so
# memory that leaves while it is held left through the delete, not through a gc.

# One f32 file per slice of a (t, y, x) array, row-major.
.ho_bins <- function(dir, name, cube) {
  vapply(
    seq_len(dim(cube)[[1L]]),
    function(t) {
      f <- file.path(dir, paste0(name, "-", t, ".bin"))
      writeBin(as.numeric(t(cube[t, , ])), f, size = 4L)
      f
    },
    ""
  )
}

# A band task over `bins`: its job and its constants.
.ho_band_job <- function(
  ck,
  bins,
  ny,
  nx,
  rows = NULL,
  masks = character(0),
  mask_y0 = 0L
) {
  list(
    job = list(cubes = list(bins), rows = rows, ck = ck),
    k = list(
      kernels = stats::setNames(
        list(list(
          F = if (length(masks)) function(x, m) x + m,
          op = "median",
          nan_rm = TRUE,
          masked = length(masks) > 0L,
          affine = list(scale = numeric(0), offset = numeric(0))
        )),
        ck
      ),
      ny = ny,
      nx = nx,
      dev = "cpu",
      mask_bins = masks,
      mask_y0 = mask_y0
    )
  )
}

.ho_run <- function(b) {
  garry:::.gd_compute_masked_band(b$job, b$k)
}

# Row-major f32 bytes as a (y, x) matrix.
.ho_cells <- function(r) {
  d <- attr(r, "gdim")
  matrix(
    readBin(as.raw(r), "numeric", prod(d), size = 4L),
    d[[1L]],
    d[[2L]],
    byrow = TRUE
  )
}

# The task's adopted arrays, as its exit saw them.
.ho_keep_inputs <- function(env = parent.frame()) {
  kept <- new.env()
  real <- garry:::.gd_drop_inputs
  testthat::local_mocked_bindings(
    .gd_drop_inputs = function() {
      kept$arrays <- garry:::.gd_inputs$live
      real()
    },
    .package = "garry",
    .env = env
  )
  kept
}

.ho_expect_deleted <- function(arrays, n) {
  expect_length(arrays, n)
  for (a in arrays) {
    expect_error(garry:::g_download_raw(a), "deleted or donated")
  }
  expect_null(garry:::.gd_inputs$live)
}

# Bytes the aligned allocator holds: blocks read and not yet released.
.ho_live <- function() {
  .Call("garry_mem_live", PACKAGE = "garry")
}

# What the allocator holds once no release is pending. No block outlives its
# task, but XLA frees a block a kernel read when that kernel lets go of it, on
# an XLA thread, which under load can come just after the task returns. Once it
# holds nothing, only this thread changes the count.
.ho_drained <- function() {
  deadline <- proc.time()[["elapsed"]] + 10
  while (.ho_live() > 0 && proc.time()[["elapsed"]] < deadline) {
    Sys.sleep(0.001)
  }
  .ho_live()
}

test_that("an adopted read holds the files' bytes and fails as an R read does", {
  dir <- withr::local_tempdir()
  cube <- array(as.numeric(1:60), c(3L, 4L, 5L))
  bins <- .ho_bins(dir, "b", cube)
  a <- garry:::.gd_upload_rows(bins, 1L, 2L, 5L, NULL)
  withr::defer(garry:::.gd_drop_inputs())
  got <- garry:::g_download_raw(a)
  expect_identical(attr(got, "gdim"), c(3L, 2L, 5L))
  want <- .Call(
    "garry_read_rows",
    bins,
    1 * 5 * 4,
    2 * 5 * 4,
    PACKAGE = "garry"
  )
  expect_identical(as.raw(got), want)
  garry:::.gd_drop_inputs()

  # a failed read frees its block before it raises, not at a later gc
  read <- function(paths, offset, bytes) {
    .Call("garry_read_rows_aligned", paths, offset, bytes, PACKAGE = "garry")
  }
  expect_identical(.ho_drained(), 0)
  expect_error(read(bins, 1e6, 4), "short read of")
  expect_identical(.ho_live(), 0)
  expect_error(read(file.path(dir, "no.bin"), 0, 4), "cannot open")
  expect_identical(.ho_live(), 0)
})

test_that("a block is 64-byte aligned, and a refused adoption leaves it to its owner", {
  dir <- withr::local_tempdir()
  f <- file.path(dir, "b.bin")
  writeBin(as.numeric(1:6), f, size = 4L)
  release <- .Call("garry_mem_release", PACKAGE = "garry")
  # Adoption itself refuses unaligned memory, so every size must pass it.
  for (bytes in c(4, 20, 60, 64, 68, 4096)) {
    writeBin(raw(bytes), f)
    mem <- .Call("garry_read_rows_aligned", f, 0, bytes, PACKAGE = "garry")
    garry:::g_delete(garry:::g_adopt_raw(
      mem,
      bytes,
      release,
      "f32",
      c(1L, bytes / 4)
    ))
  }
  mem <- .Call("garry_read_rows_aligned", f, 0, 4096, PACKAGE = "garry")
  expect_error(
    garry:::g_adopt_raw(mem, 4092, release, "f32", c(1L, 1024L)),
    "bytes"
  )
  a <- garry:::g_adopt_raw(mem, 4096, release, "f32", c(1L, 1024L))
  expect_identical(attr(garry:::g_download_raw(a), "gdim"), c(1L, 1024L))
  garry:::g_delete(a)
  # A block no buffer took goes with its pointer.
  gc()
  expect_identical(.ho_drained(), 0)
  mem <- .Call("garry_read_rows_aligned", f, 0, 4096, PACKAGE = "garry")
  expect_identical(.ho_live(), 4096)
  rm(mem)
  gc()
  expect_identical(.ho_live(), 0)
  expect_null(garry:::.gd_inputs$live)
})

test_that("a strip and its mask reach the kernel from the right rows", {
  dir <- withr::local_tempdir()
  ck <- "handover-rows"
  .local_kernel_cache()
  band <- array(as.numeric(seq_len(60L)^2), c(3L, 4L, 5L))
  # The mask's window starts a row above the strip's.
  mask <- array(as.numeric(seq_len(75L)), c(3L, 5L, 5L))
  b <- .ho_band_job(
    ck,
    .ho_bins(dir, "b", band),
    4L,
    5L,
    rows = c(1L, 2L),
    masks = .ho_bins(dir, "m", mask),
    mask_y0 = 1L
  )
  kept <- .ho_keep_inputs()
  out <- .ho_run(b)
  rows <- 2:3
  want <- apply(band[, rows, ] + mask[, rows + 1L, ], c(2L, 3L), stats::median)
  expect_equal(.ho_cells(out), unname(want), tolerance = 1e-5)
  .ho_expect_deleted(kept$arrays, 2L)
})

test_that("a mask task reads through adoption and writes each slice", {
  dir <- withr::local_tempdir()
  ck <- "handover-mask"
  .local_kernel_cache()
  cube <- array(as.numeric(1:24), c(2L, 3L, 4L))
  bins <- .ho_bins(dir, "f", cube)
  want <- lapply(bins, readBin, "raw", file.size(bins[[1L]]))
  out <- file.path(dir, c("m1.bin", "m2.bin"))
  kept <- .ho_keep_inputs()
  garry:::.gd_compute_mask(
    list(fmask_bins = bins, out_bins = out, free = bins),
    list(chain = list(), halo = 0L, ny = 3L, nx = 4L, dev = "cpu", ck = ck)
  )
  expect_identical(lapply(out, readBin, "raw", file.size(out[[1L]])), want)
  expect_false(any(file.exists(bins)))
  .ho_expect_deleted(kept$arrays, 1L)
})

test_that("a device reads through R's heap and gives the same cells", {
  dir <- withr::local_tempdir()
  cube <- array(as.numeric(seq_len(60L)^2), c(3L, 4L, 5L))
  bins <- .ho_bins(dir, "b", cube)
  .local_kernel_cache()
  adopted <- .ho_run(.ho_band_job("handover-cpu", bins, 4L, 5L))
  kept <- .ho_keep_inputs()
  # No card here, so name the CPU as a device: that takes the device's branch.
  testthat::local_mocked_bindings(
    .exec_device = function(device) "cpu",
    .package = "garry"
  )
  uploaded <- .ho_run(.ho_band_job("handover-dev", bins, 4L, 5L))
  expect_identical(as.raw(uploaded), as.raw(adopted))
  expect_null(kept$arrays)
})

test_that("a short read is loud and frees the reads before it", {
  dir <- withr::local_tempdir()
  ck <- "handover-short"
  .local_kernel_cache()
  band <- array(as.numeric(1:60), c(3L, 4L, 5L))
  masks <- .ho_bins(dir, "m", band)
  writeBin(readBin(masks[[3L]], "raw", 8L), masks[[3L]])
  b <- .ho_band_job(ck, .ho_bins(dir, "b", band), 4L, 5L, masks = masks)
  kept <- .ho_keep_inputs()
  expect_error(.ho_run(b), "short read of .*m-3\\.bin: 8 of 80 bytes")
  .ho_expect_deleted(kept$arrays, 1L)

  b$k$mask_bins[[3L]] <- file.path(dir, "gone.bin")
  expect_error(.ho_run(b), "cannot open .*gone\\.bin")
  .ho_expect_deleted(kept$arrays, 1L)
})

test_that("an R error with the kernel in flight frees the task's reads", {
  dir <- withr::local_tempdir()
  ck <- "handover-r-error"
  cache <- .local_kernel_cache()
  cube <- array(as.numeric(1:60), c(3L, 4L, 5L))
  b <- .ho_band_job(ck, .ho_bins(dir, "b", cube), 4L, 5L)
  good <- .ho_run(b)
  real <- get(ck, envir = cache)
  assign(
    ck,
    function(inputs) {
      real(inputs)
      stop("after the kernel started")
    },
    envir = cache
  )
  kept <- .ho_keep_inputs()
  expect_error(.ho_run(b), "after the kernel started")
  .ho_expect_deleted(kept$arrays, 1L)
  assign(ck, real, envir = cache)
  expect_identical(as.raw(.ho_run(b)), as.raw(good))
})

test_that("an error after the kernel frees a mask task's read", {
  dir <- withr::local_tempdir()
  ck <- "handover-write-error"
  .local_kernel_cache()
  bins <- .ho_bins(dir, "f", array(as.numeric(1:24), c(2L, 3L, 4L)))
  kept <- .ho_keep_inputs()
  expect_error(
    garry:::.gd_compute_mask(
      list(
        fmask_bins = bins,
        out_bins = file.path(dir, "no", c("m1.bin", "m2.bin")),
        free = bins
      ),
      list(chain = list(), halo = 0L, ny = 3L, nx = 4L, dev = "cpu", ck = ck)
    ),
    "cannot write"
  )
  .ho_expect_deleted(kept$arrays, 1L)
  expect_true(all(file.exists(bins)))
})

test_that("an XLA rejection frees the task's reads", {
  dir <- withr::local_tempdir()
  ck <- "handover-xla-error"
  cache <- .local_kernel_cache()
  exe <- pjrt::pjrt_compile(pjrt::pjrt_program(
    src = paste(
      "func.func @main(%x: tensor<2x2xf32>) -> tensor<2x2xf32> {",
      "%0 = stablehlo.add %x, %x : tensor<2x2xf32>",
      "return %0 : tensor<2x2xf32>",
      "}",
      sep = "\n"
    ),
    format = "mlir"
  ))
  assign(
    ck,
    function(inputs) list(pjrt::pjrt_execute(exe, inputs[[1L]]$data)),
    envir = cache
  )
  b <- .ho_band_job(
    ck,
    .ho_bins(dir, "b", array(as.numeric(1:60), c(3L, 4L, 5L))),
    4L,
    5L
  )
  kept <- .ho_keep_inputs()
  expect_error(.ho_run(b), "expected parameter 0")
  .ho_expect_deleted(kept$arrays, 1L)
})

test_that("a read's memory goes with no gc while its handle is held", {
  dir <- withr::local_tempdir()
  f <- file.path(dir, "b.bin")
  ny <- 64L
  nx <- 128L
  writeBin(raw(ny * nx * 4L), f)
  bins <- rep(f, 16L)
  # Before the read: a block an earlier test left unreachable goes now.
  gc()
  expect_identical(.ho_drained(), 0)
  held <- garry:::.gd_upload_rows(bins, 0L, ny, nx, NULL)
  expect_identical(.ho_live(), 16 * ny * nx * 4)
  # A task that fails on its next read drops it. `held` keeps the handle
  # reachable, so no finalizer can be what freed the memory, and no kernel read
  # it, so the delete frees it at once.
  expect_error(
    garry:::.gd_compute_masked_band(
      list(
        cubes = list(rep(file.path(dir, "gone.bin"), 16L)),
        rows = NULL,
        ck = "unused"
      ),
      list(
        ny = ny,
        nx = nx,
        dev = "cpu",
        mask_bins = character(0),
        mask_y0 = 0L
      )
    ),
    "cannot open"
  )
  expect_identical(.ho_live(), 0)
  expect_error(garry:::g_download_raw(held), "deleted or donated")
})

test_that("repeat tasks give back every read with no gc", {
  dir <- withr::local_tempdir()
  ck <- "handover-repeat"
  .local_kernel_cache()
  f <- file.path(dir, "b.bin")
  ny <- 256L
  nx <- 256L
  writeBin(as.numeric(seq_len(ny * nx)), f, size = 4L)
  b <- .ho_band_job(ck, rep(f, 3L), ny, nx)
  .ho_run(b)
  gc()
  expect_identical(.ho_drained(), 0)
  # Every task's arrays stay reachable, so only the delete can free their reads.
  held <- list()
  real <- garry:::.gd_drop_inputs
  testthat::local_mocked_bindings(
    .gd_drop_inputs = function() {
      held <<- c(held, garry:::.gd_inputs$live)
      real()
    },
    .package = "garry"
  )
  for (i in 1:50) {
    .ho_run(b)
  }
  expect_length(held, 50L)
  expect_identical(.ho_drained(), 0)
  expect_null(garry:::.gd_inputs$live)
})
