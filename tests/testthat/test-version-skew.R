# Host/daemon ABI skew guard: daemons resolve the .daemon_* bodies from the
# INSTALLED library while a dev host often runs a load_all() tree. The
# formals-hash token (.garry_abi_token) is compared host-vs-daemon once
# per pool generation at execute_plan_mirai entry; a mismatch is a
# classed garry_version_skew_error instead of undefined behavior
# mid-drain ("unused argument" task errors, silent semantic drift).

# garry_daemons() clears the check, which test-routed-dispatch.R holds on a
# real new generation. Each test here starts from that state.
local({
  local_pools(2, 1)
  state <- garry:::.garry_state
  f <- fixture_gradient_f32()

  test_that("matching tokens pass and the check caches per pool generation", {
    state$abi_ok <- NULL
    n <- 0L
    real <- garry:::.garry_abi_token
    testthat::local_mocked_bindings(
      .garry_abi_token = function() {
        n <<- n + 1L
        real()
      },
      .package = "garry"
    )
    x <- lazy_source(f) + 1
    invisible(collect(x, distributed = TRUE))
    expect_true(isTRUE(state$abi_ok))
    expect_identical(n, 1L)
    # a second run takes the cached answer and asks nobody
    got <- collect(x, distributed = TRUE)
    expect_identical(n, 1L)
    expect_equal(dim(got), c(40L, 60L))
  })

  test_that("a skewed token aborts classed, naming both hashes", {
    state$abi_ok <- NULL
    daemon <- garry:::.garry_abi_token()
    # Skew the HOST side; the daemons answer with the real installed token.
    testthat::local_mocked_bindings(
      .garry_abi_token = function() "deadbeef-host-token",
      .package = "garry")
    err <- expect_error(collect(lazy_source(f) + 1, distributed = TRUE),
                        class = "garry_version_skew_error")
    expect_match(conditionMessage(err), "deadbeef-host-token", fixed = TRUE)
    expect_match(conditionMessage(err), daemon, fixed = TRUE)
  })

  test_that("a daemon that cannot answer says why, and is not called skewed", {
    state$abi_ok <- NULL
    .everywhere({
      ns <- asNamespace("garry")
      unlockBinding(".garry_abi_token", ns)
      .vs_real <<- get(".garry_abi_token", envir = ns)
      assign(".garry_abi_token", function() stop("package garry is broken here"), envir = ns)
    }, .compute = "garry_write")
    withr::defer(.everywhere(
      assign(".garry_abi_token", .vs_real, envir = asNamespace("garry")),
      .compute = "garry_write"
    ))
    err <- expect_error(
      garry:::.garry_abi_check("garry_write"),
      class = "garry_version_skew_error"
    )
    expect_match(conditionMessage(err), "package garry is broken here", fixed = TRUE)
  })
})

test_that("every cross-process entry point is in the ABI token", {
  code <- unlist(lapply(.r_sources(), readLines, warn = FALSE))
  code <- sub("^\\s*#.*$", "", code) # roxygen and comments
  m <- regmatches(code, gregexpr('asNamespace\\("garry"\\)\\$[.A-Za-z_]+', code))
  called <- unique(sub(".*\\$", "", unlist(m)))
  called <- called[!grepl("^\\.daemon_", called) & called != ".garry_abi_token"]
  expect_gt(length(called), 0L)
  expect_setequal(called, garry:::.garry_abi_extra)
})
