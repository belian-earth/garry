# The one way to run garry's tests: Rscript tools/test.R [regex]
#
# Run from the package root. The regex picks test files by name (test-<name>.R);
# with none, the whole suite runs. Four workers, then totals and failures.
#
# Install first. Tests and daemons load the installed garry, not this tree:
#
#   R CMD INSTALL --no-docs --no-test-load .
#
# Confine the run. Each worker starts up to eight processes, and a run outside a
# scope can take a desktop session down with it:
#
#   systemd-run --user --scope -q -p MemoryMax=24G -p MemorySwapMax=0 \
#     Rscript tools/test.R 'pool|route-matrix'
#
# Changed R/foo.R? Run 'foo'. These have no test of their name:
#
#   R/scheduler.R  scheduler|route-matrix|route-dtype|routed|mirai|read-budget|mem-admission
#   R/pools.R      pool|mirai|route-dtype|routed|rss-correction|version-skew
#   R/daemon.R     kernel|jit-key|hygiene|version-skew|writer-errors
#   R/collect.R    route-matrix|read-only|multi-export|collect
#   R/executor.R   executor|plan-oracle|halo|edge-chunks

Sys.setenv(NOT_CRAN = "true", TESTTHAT_PARALLEL = "true", TESTTHAT_CPUS = "4")
library(testthat)
library(garry)

regex <- commandArgs(TRUE)
t0 <- Sys.time()
chatter <- capture.output(res <- test_dir( # what workers print: run progress
  "tests/testthat",
  filter = if (length(regex)) regex[[1L]],
  reporter = "silent",
  stop_on_failure = FALSE,
  package = "garry",
  load_package = "installed"
))
d <- as.data.frame(res)
secs <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")))
n_bad <- sum(d$failed) + sum(d$error)
cat(glue::glue("TOTAL {sum(d$nb)} FAILED {n_bad} SKIP {sum(d$skipped)} WALL {secs}s"), "\n")
for (r in res) {
  for (x in r$results) {
    if (inherits(x, c("expectation_failure", "expectation_error"))) {
      cat(glue::glue("[{r$file}] {r$test}: {conditionMessage(x)}"), "\n")
    }
  }
}
quit(save = "no", status = as.integer(n_bad > 0))
