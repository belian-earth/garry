# Extracted from test-gdal-quarantine.R:22

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "garry", path = "..")
attach(test_env, warn.conflicts = FALSE)

# test -------------------------------------------------------------------------
r_dir <- testthat::test_path("..", "..", "R")
skip_if(!dir.exists(r_dir), "package sources not available")
files <- setdiff(list.files(r_dir, pattern = "\\.R$", full.names = TRUE),
                   file.path(r_dir, "gdal_adapter.R"))
offenders <- character(0)
for (f in files) {
    lines <- readLines(f, warn = FALSE)
    code <- sub("#.*$", "", lines)
    hits <- regmatches(code, gregexpr("gdalraster::[A-Za-z_.0-9]+", code))
    hits <- unlist(hits)
    bad <- hits[!grepl("^gdalraster::(srs_|transform_)", hits)]
    if (length(bad) > 0L)
      offenders <- c(offenders, paste0(basename(f), ": ",
                                       paste(unique(bad), collapse = ", ")))
  }
expect_identical(offenders, character(0))
