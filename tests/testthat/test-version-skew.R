# Host/daemon ABI skew guard: daemons resolve garry::.daemon_* from the
# INSTALLED library while a dev host often runs a load_all() tree. The
# formals-hash token (.garry_abi_token) is compared host-vs-daemon once
# per pool generation at execute_plan_mirai entry; a mismatch is a
# classed garry_version_skew_error instead of undefined behavior
# mid-drain ("unused argument" mirai errors, silent semantic drift).

skip_if_not_installed("anvl")
skip_if_not_installed("mirai")
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
