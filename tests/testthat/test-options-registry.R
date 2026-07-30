# Option registry (garry_options()) and value validation
# (.garry_opt_check at execute entry): every option carries a tier and
# description, every default validates, and a typo'd VALUE fails loudly
# instead of silently meaning something else (a read_fail typo used to
# silently mean "error").

test_that("every option is registered and every default validates", {
  expect_setequal(names(garry:::.garry_opt_info),
                  names(garry:::.garry_defaults))
  expect_no_error(garry:::.garry_opt_check())
  reg <- garry_options()
  expect_setequal(reg$option, names(garry:::.garry_defaults))
  expect_true(all(reg$tier %in% c("user", "tuning", "calibration")))
  expect_true(all(nzchar(reg$description)))
})

test_that("a read_fail typo errors classed instead of silently meaning 'error'", {
  withr::local_options(garry.read_fail = "nodta")
  err <- expect_error(garry:::.garry_opt_check(),
                      class = "garry_option_error")
  expect_match(conditionMessage(err), "read_fail")
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
  skip_if_not_installed("anvl")
  withr::local_options(garry.read_fail = "nodta")
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
