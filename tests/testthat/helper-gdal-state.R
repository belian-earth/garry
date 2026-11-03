# GDAL's error handler and config options are process-wide, and two packages
# the suite uses rewrite them on load. Every test has to see the same state,
# whatever ran before it on its worker, so this file settles what that state is.

# rstac imports sf, whose error handler replaces gdalraster's and turns GDAL
# failures into R warnings. The STAC tests need rstac in this process, and it
# changes nothing else, so every worker loads it from the start.
requireNamespace("rstac", quietly = TRUE)

# The value of `f(x)` in an R process of its own, with terra loaded there;
# skips where terra will not load. terra replaces the error handler and also
# sets GDAL_MAX_BAND_COUNT and CPL_VSIL_USE_TEMP_FILE_FOR_RANDOM_WRITE, which
# no session without terra has, so it stays out of the test workers.
# skip_if_not_installed() and rlang::is_installed() would load it here.
.with_terra <- function(f, x) {
  prof <- "garry_test_terra"
  mirai::daemons(1L, dispatcher = FALSE, .compute = prof)
  on.exit(mirai::daemons(0L, .compute = prof))
  environment(f) <- globalenv()
  got <- mirai::call_mirai(mirai::mirai(
    if (requireNamespace("terra", quietly = TRUE)) f(x),
    f = f,
    x = x,
    .compute = prof
  ))$data
  if (mirai::is_error_value(got)) {
    stop(as.character(got), call. = FALSE)
  }
  testthat::skip_if(is.null(got), "terra cannot be loaded")
  got
}
