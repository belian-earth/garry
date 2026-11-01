# Generate the rustyfilters fixture for garry's bilateral filter tests.
#
# Run once, from the package root, on a machine with rustyfilters installed:
#
#     Rscript tools/rustyfilters_make_fixture.R
#
# Writes tests/testthat/fixtures/rustyfilters/bilateral.rds: a small noisy
# surface with a sharp spike and NaN holes, one of them in a corner, and
# rf_bilateral's answer on it. test-focal-bilateral.R ties bilateral_focal()
# and its pure-R reference to that answer, so the tests hold without
# rustyfilters installed.

out <- "tests/testthat/fixtures/rustyfilters/bilateral.rds"

set.seed(31)
m <- matrix(stats::rnorm(12 * 10), 12, 10)
m[6, 5] <- 8
m[c(3, 9), c(4, 8)] <- NaN
m[12, 1] <- NaN
sigma_d <- 1
sigma_r <- 1.3
rf <- rustyfilters::rf_bilateral(
  m,
  sigma_d = sigma_d,
  sigma_r = sigma_r,
  window = 3L,
  edge = "shrink",
  na_policy = "omit"
)

dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
saveRDS(
  list(
    meta = list(
      generator = "tools/rustyfilters_make_fixture.R",
      oracle = paste("rustyfilters", utils::packageVersion("rustyfilters")),
      r = R.version.string,
      date = format(Sys.Date())
    ),
    cases = list(m = m, sigma_d = sigma_d, sigma_r = sigma_r, rf = rf)
  ),
  out,
  version = 2,
  compress = "xz"
)
