# Decision D3 lock: XLA-style promotion. The literal table below is the
# contract; changing promotion behaviour means consciously editing it.

test_that("promotion is commutative and idempotent", {
  dts <- c("f32", "f64", "i8", "i16", "i32", "i64",
           "u8", "u16", "u32", "u64", "pred")
  for (a in dts) {
    expect_identical(dtype_promote(a, a), a)
    for (b in dts) {
      expect_identical(dtype_promote(a, b), dtype_promote(b, a))
    }
  }
})

test_that("promotion matches the locked spot table", {
  # (a, b, expected) — the canonical cases, hand-written.
  cases <- list(
    # float dominance (never R's f64 for f32+int)
    c("f32", "i32",  "f32"),
    c("f32", "i64",  "f32"),
    c("f32", "u16",  "f32"),
    c("f64", "i32",  "f64"),
    c("f32", "f64",  "f64"),
    # within-family widening
    c("i8",  "i32",  "i32"),
    c("i16", "i64",  "i64"),
    c("u8",  "u32",  "u32"),
    c("u16", "u64",  "u64"),
    # pred promotes to the other operand
    c("pred", "f32", "f32"),
    c("pred", "i16", "i16"),
    c("pred", "u8",  "u8"),
    # signed/unsigned: signed wide enough for both
    c("i32", "u8",   "i32"),
    c("i32", "u16",  "i32"),
    c("i32", "u32",  "i64"),
    c("i16", "u16",  "i32"),
    c("i64", "u32",  "i64"),
    c("i8",  "u8",   "i16"),
    # u64 has no signed container -> f64 (NumPy convention)
    c("i32", "u64",  "f64"),
    c("i64", "u64",  "f64")
  )
  for (cs in cases) {
    expect_identical(dtype_promote(cs[1], cs[2]), cs[3],
                     label = paste(cs[1], "+", cs[2]))
  }
})

test_that("division always yields float", {
  expect_identical(dtype_promote("i32", "i32", divide = TRUE), "f32")
  expect_identical(dtype_promote("i16", "u8",  divide = TRUE), "f32")
  expect_identical(dtype_promote("i64", "i64", divide = TRUE), "f64")
  expect_identical(dtype_promote("i32", "u32", divide = TRUE), "f64") # i64 carrier
  expect_identical(dtype_promote("u64", "i8",  divide = TRUE), "f64")
  expect_identical(dtype_promote("pred", "pred", divide = TRUE), "f32")
  # floats unchanged
  expect_identical(dtype_promote("f32", "f32", divide = TRUE), "f32")
  expect_identical(dtype_promote("f32", "i32", divide = TRUE), "f32")
  expect_identical(dtype_promote("f64", "f32", divide = TRUE), "f64")
})

test_that("invalid dtypes are rejected", {
  expect_error(dtype_promote("f16", "f32"), "invalid dtype")
  expect_error(dtype_promote("f32", "double"), "invalid dtype")
  expect_false(dtype_valid("float32"))
  expect_true(dtype_valid("u16"))
})

test_that("g_upload maps NaN to 0 for integer dtypes and keeps it for floats", {
  skip_if_not_installed("anvl")
  x <- matrix(c(1, NaN, 3, NA, 5, 6), 2L, 3L)
  # signed integer, and an unsigned dtype that uploads through a wider carrier
  for (dt in c("i16", "i32", "u8")) {
    got <- g_download(g_upload(x, dt))
    expect_equal(as.numeric(got), c(1, 0, 3, 0, 5, 6), info = dt)
  }
  f <- g_download(g_upload(x, "f32"))
  expect_true(all(is.nan(f[c(2L, 4L)])))
  expect_equal(f[-c(2L, 4L)], c(1, 3, 5, 6))
})
