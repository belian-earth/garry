# Spike 03: integer + bitwise ops for QA band decoding.
# Pattern: Landsat/HLS Fmask-style bit flags; extract bit, build mask,
# apply to a float band via nv_ifelse.

library(anvl)

npx <- 128L
set.seed(3)
qa_r <- matrix(sample(0:65535, npx^2, replace = TRUE), npx, npx)
band_r <- matrix(runif(npx^2), npx, npx)

# Cloud = bit 10, shadow = bit 11 (Sentinel-2 L1C style).
mask_apply <- function(band, qa) {
  cloud  <- nv_and(nv_shift_right_logical(qa, nv_scalar_like(qa, 10L)),
                   nv_scalar_like(qa, 1L))
  shadow <- nv_and(nv_shift_right_logical(qa, nv_scalar_like(qa, 11L)),
                   nv_scalar_like(qa, 1L))
  bad <- nv_or(nv_eq(cloud, nv_scalar_like(qa, 1L)),
               nv_eq(shadow, nv_scalar_like(qa, 1L)))
  nv_ifelse(bad, nv_scalar(NaN, "f32"), band)
}

f <- jit(mask_apply)
got <- as_array(f(nv_array(band_r, "f32"), nv_array(qa_r, dtype = "i32")))

bad_r <- bitwAnd(bitwShiftR(qa_r, 10), 1) == 1 | bitwAnd(bitwShiftR(qa_r, 11), 1) == 1
want <- band_r
want[bad_r] <- NaN

stopifnot(identical(is.nan(got), is.nan(want)))
stopifnot(max(abs(got[!is.nan(got)] - want[!is.nan(want)])) < 1e-7)
cat("bit extraction + mask application: exact match on", sum(bad_r), "masked pixels\n")

# dtype conversion: i32 QA -> f32 for arithmetic reuse.
conv <- jit(function(qa) nv_convert(qa, "f32"))
stopifnot(max(abs(as_array(conv(nv_array(qa_r, dtype = "i32"))) - qa_r)) == 0)

cat("PASS: integer, shift, and bitwise ops cover QA decoding\n")
