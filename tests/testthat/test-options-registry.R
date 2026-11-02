# Option registry (garry_options()) and value validation
# (.garry_opt_check at execute entry): every option carries a tier and
# description, every default validates, and a typo'd name or VALUE fails
# loudly instead of silently meaning something else.

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
  expect_false(garry_opt("warp_exact")) # exactness is opted into
  # garry_opt() fails on an unknown name only when a run reaches that line
  code <- unlist(lapply(.r_sources(), readLines, warn = FALSE))
  code <- sub("^\\s*#.*$", "", code) # roxygen and comments
  m <- regmatches(code, gregexpr('garry_opt\\("[a-z0-9_]+"\\)', code))
  read <- unique(gsub('^garry_opt\\("|"\\)$', "", unlist(m)))
  expect_gt(length(read), 20L)
  expect_identical(setdiff(read, names(garry:::.garry_defaults)), character(0))
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
