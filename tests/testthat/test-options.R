
test_that("an out-of-range integer option is a classed option error", {
  withr::local_options(garry.handle_cache_max = 1e12)
  expect_error(garry:::.garry_opt_check(), class = "garry_option_error")
})
