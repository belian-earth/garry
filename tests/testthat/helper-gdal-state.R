# GDAL's error handler and config options are process-wide, and two packages
# the suite uses rewrite them on load. Every test has to see the same state,
# whatever ran before it on its worker, so this file settles what that state is.

# rstac imports sf, whose error handler replaces gdalraster's and turns GDAL
# failures into R warnings. The STAC tests need rstac in this process, and it
# changes nothing else, so every worker loads it from the start.
requireNamespace("rstac", quietly = TRUE)

# GDAL's report of a failure or warning, in each form a handler gives it, and
# gdalraster's own warning when a flush or close fails.
.gdal_says <- c(
  "^(\\S+ )?GDAL (FAILURE|WARNING|Error|Message) [0-9]+: ",
  "^error occurred during GDAL[A-Za-z]+\\(\\)!$"
)

# Run `code`, muffling GDAL's reports that match `what`, a pattern for the
# cause the test provokes. The process's error handler decides their form:
# gdalraster's alone alerts through cli, while with sf loaded (above) its
# handler or sf's raises an R warning. So a test cannot expect a report of the
# failure it provokes, only muffle it. Every other condition passes.
.gdal_hushed <- function(code, what) {
  stopifnot(is.character(what), length(what) == 1L, nzchar(what))
  hush <- function(cnd) {
    said <- trimws(cli::ansi_strip(conditionMessage(cnd)))
    if (any(vapply(.gdal_says, grepl, NA, x = said)) && grepl(what, said)) {
      kind <- if (inherits(cnd, "warning")) "Warning" else "Message"
      invokeRestart(paste0("muffle", kind))
    }
  }
  withCallingHandlers(code, warning = hush, message = hush)
}

# GDAL's report that the file at `path` is not there, as a pattern for
# .gdal_hushed(). The report names the file, so a report of any other missing
# file still passes.
.gdal_missing <- function(path) {
  file <- gsub("([][{}()^$.|*+?\\\\])", "\\\\\\1", basename(path))
  paste0(file, ": No such file or directory")
}

# Run `code`, muffling only gdalraster's note on each open of an Int64 or
# UInt64 file, which it reads as doubles. For a file a test wrote itself: every
# such file holds values a double keeps exactly, so the note says nothing about
# a test.
.int64_note <- "Int64/UInt64 raster data are currently handled as 'double'"
.int64_hushed <- function(code) {
  withCallingHandlers(code, warning = function(w) {
    if (identical(conditionMessage(w), .int64_note)) {
      invokeRestart("muffleWarning")
    }
  })
}

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
