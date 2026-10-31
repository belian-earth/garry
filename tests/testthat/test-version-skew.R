# Host/daemon ABI skew guard: daemons resolve the .daemon_* bodies from the
# INSTALLED library while a dev host often runs a load_all() tree. The
# formals-hash token (.garry_abi_token) is compared host-vs-daemon once
# per pool generation at execute_plan_mirai entry; a mismatch is a
# classed garry_version_skew_error instead of undefined behavior
# mid-drain ("unused argument" mirai errors, silent semantic drift).

skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")

test_that("matching tokens pass and the check caches per pool generation", {
  local_pools(2, 1)
  expect_null(garry:::.garry_state$abi_ok)      # fresh pools: unchecked
  f <- fixture_gradient_f32()
  got <- collect(lazy_source(f) + 1, distributed = TRUE)
  expect_true(isTRUE(garry:::.garry_state$abi_ok))
  expect_equal(dim(got), c(40L, 60L))
})

test_that("a skewed token aborts classed, naming both hashes", {
  local_pools(2, 1)
  # Skew the HOST side; the daemons answer with the real installed token.
  testthat::local_mocked_bindings(
    .garry_abi_token = function() "deadbeef-host-token",
    .package = "garry")
  f <- fixture_gradient_f32()
  err <- expect_error(collect(lazy_source(f) + 1, distributed = TRUE),
                      class = "garry_version_skew_error")
  expect_match(conditionMessage(err), "deadbeef-host-token")
})

test_that("a daemon that cannot answer says why, and is not called skewed", {
  local_pools(1, 1)
  mirai::everywhere({
    ns <- asNamespace("garry")
    unlockBinding(".garry_abi_token", ns)
    assign(".garry_abi_token", function() stop("package garry is broken here"), envir = ns)
  }, .compute = "garry_write")
  err <- expect_error(
    garry:::.garry_abi_check("garry_write"),
    class = "garry_version_skew_error"
  )
  expect_match(conditionMessage(err), "package garry is broken here", fixed = TRUE)
})

test_that("every cross-process entry point is in the ABI token", {
  r_dir <- testthat::test_path("..", "..", "R")
  skip_if(!dir.exists(r_dir), "package sources not available")
  code <- unlist(lapply(
    list.files(r_dir, pattern = "\\.R$", full.names = TRUE),
    readLines,
    warn = FALSE
  ))
  code <- sub("^\\s*#.*$", "", code) # roxygen and comments
  m <- regmatches(code, gregexpr('asNamespace\\("garry"\\)\\$[.A-Za-z_]+', code))
  called <- unique(sub(".*\\$", "", unlist(m)))
  called <- called[!grepl("^\\.daemon_", called) & called != ".garry_abi_token"]
  expect_gt(length(called), 0L)
  expect_setequal(called, garry:::.garry_abi_extra)
})
