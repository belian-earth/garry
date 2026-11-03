# A failed read is what these tests are about, so nothing here waits out a
# retry's backoff. test-read-retry.R sets its own.
withr::local_options(garry.read_retry = 0L, .local_envir = testthat::teardown_env())
