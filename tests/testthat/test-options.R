
test_that("an out-of-range integer option is a classed option error", {
  withr::local_options(garry.read_handles = 1e12)
  expect_error(garry:::.garry_opt_check(), class = "garry_option_error")
})

test_that("a garry option with no such name fails, it does not mean the default", {
  withr::local_options(garry.read_retyr = 5, garry.zzz = TRUE)
  err <- expect_error(garry:::.garry_opt_check(), class = "garry_option_error")
  expect_match(conditionMessage(err), "garry.read_retyr", fixed = TRUE)
  expect_match(conditionMessage(err), "garry.zzz", fixed = TRUE)
})

test_that("every option the package reads is registered", {
  expect_no_error(garry_opt("warp_exact"))
  expect_identical(garry_opt("warp_exact"), FALSE)
})
