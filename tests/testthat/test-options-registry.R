# Option registry (garry_options()) and value validation
# (.garry_opt_check at execute entry): every option carries a tier and
# description, every default validates, and a typo'd VALUE fails loudly
# instead of silently meaning something else.

test_that("every option is registered and every default validates", {
  expect_setequal(names(garry:::.garry_options_table),
                  names(garry:::.garry_defaults))
  expect_no_error(garry:::.garry_opt_check())
  reg <- garry_options()
  expect_setequal(reg$option, names(garry:::.garry_defaults))
  expect_true(all(reg$tier %in% c("user", "tuning")))
  expect_true(all(nzchar(reg$description)))
})

test_that("a fetch typo errors classed instead of silently meaning another mode", {
  withr::local_options(garry.fetch = "forse")
  err <- expect_error(garry:::.garry_opt_check(),
                      class = "garry_option_error")
  expect_match(conditionMessage(err), "fetch")
})

test_that("out-of-range values name the offending option", {
  withr::local_options(garry.exec_ram_fraction = 2)
  err <- expect_error(garry:::.garry_opt_check(),
                      class = "garry_option_error")
  expect_match(conditionMessage(err), "exec_ram_fraction")
  withr::local_options(garry.exec_ram_fraction = 0.5,
                       garry.read_retry = -1)
  expect_error(garry:::.garry_opt_check(), class = "garry_option_error")
})

test_that("collect refuses to run under an invalid option", {
  withr::local_options(garry.fetch = "forse")
  f <- fixture_gradient_f32()
  expect_error(collect(lazy_source(f) + 1, distributed = FALSE),
               class = "garry_option_error")
})

test_that("garry_options reports session overrides", {
  withr::local_options(garry.progress = TRUE)
  reg <- garry_options()
  row <- reg[reg$option == "progress", ]
  expect_true(row$set)
  expect_identical(row$current, "TRUE")
  expect_identical(row$default, "FALSE")
})

test_that("a fractional strip count is an error, not auto", {
  withr::local_options(garry.gd_strips = 0.5)
  expect_error(garry:::.garry_opt_check(), class = "garry_option_error")
})
