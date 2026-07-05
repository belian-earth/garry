# Decision D13 lock, part 2: GDAL conventions are quarantined. Only
# R/gdal_adapter.R may call gdalraster, except the sanctioned SRS and
# bounds helpers (srs_*, transform_*) used by grid.R / chunk_grid.R.

test_that("no gdalraster:: outside the adapter beyond srs_*/transform_*", {
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
})
