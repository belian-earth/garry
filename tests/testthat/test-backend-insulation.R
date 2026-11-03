# Decision D9 lock: R/ops.R is the ONLY file that may reference anvl's
# nv_* API. Everything else goes through the garry op vocabulary, so a
# backend swap (or a torch benchmark harness) touches one file.

test_that("no nv_ references outside R/ops.R", {
  files <- .r_sources()
  files <- files[basename(files) != "ops.R"]
  offenders <- character(0)
  for (f in files) {
    lines <- readLines(f, warn = FALSE)
    code <- sub("#.*$", "", lines)          # ignore comments
    hits <- grep("\\bnv_[a-z_]+\\s*\\(", code)
    if (length(hits) > 0L)
      offenders <- c(offenders, paste0(basename(f), ":", hits))
  }
  expect_identical(offenders, character(0))
})

test_that("no direct pjrt:: calls outside R/ops.R", {
  files <- .r_sources()
  files <- files[basename(files) != "ops.R"]
  offenders <- character(0)
  for (f in files) {
    lines <- readLines(f, warn = FALSE)
    code <- sub("#.*$", "", lines)
    hits <- grep("pjrt::", code)
    if (length(hits) > 0L) {
      offenders <- c(offenders, paste0(basename(f), ":", hits))
    }
  }
  expect_identical(offenders, character(0))
})

test_that("no direct anvl:: calls outside R/ops.R", {
  files <- .r_sources()
  files <- files[basename(files) != "ops.R"]
  offenders <- character(0)
  for (f in files) {
    lines <- readLines(f, warn = FALSE)
    code <- sub("#.*$", "", lines)
    hits <- grep("anvl::", code)
    if (length(hits) > 0L)
      offenders <- c(offenders, paste0(basename(f), ":", hits))
  }
  expect_identical(offenders, character(0))
})
