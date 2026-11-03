# Plans held to a value worked out in plain R. Route equality cannot see a
# bug two routes share, and a sweep says nothing about a route it did not
# take, so each leg compares its result to `want` exactly and reports the
# path it ran on.

# What arithmetic on `dtype` declares: an unsigned value computes in a signed
# carrier, so a result can leave the unsigned range.
.carried <- function(dtype) {
  carrier <- c(u8 = "i16", u16 = "i32", u32 = "i64")
  if (dtype %in% names(carrier)) carrier[[dtype]] else dtype
}

# The f32 nearest a double, in plain R: what a plan declaring f32 can hold.
.as_f32 <- function(x) {
  out <- readBin(writeBin(as.numeric(x), raw(), size = 4L), "numeric", length(x), size = 4L)
  dim(out) <- dim(x)
  out
}

# One way to run a plan. `route` is what garry_last_route() must report.
# `decision` is what the placement pass must choose for every chain in the
# plan ("none" when it has none); the task log then shows the chain ran
# there. NULL asserts nothing, for routes without a placement pass.
.leg <- function(route = "scheduler", decision = NULL, opts = list(),
                 distributed = route != "single") {
  list(route = route, decision = decision, opts = opts, distributed = distributed)
}

.host <- .leg("single")
# A plan that only reads, copied into place in process or on the read pool.
.read_host <- .leg("read_only", distributed = FALSE)
.read_pool <- .leg("read_only", distributed = TRUE)
# Rules keep a sink's kernel on the compute pool; cost fuses it on the read
# tasks that feed it, while the machine has the RAM. The cost leg fixes that
# reading, so what it asserts is the pass and not the host's free memory.
.comp <- .leg(decision = "comp", opts = list(garry.placement = "rules"))
.fused <- .leg(decision = "fuse", opts = list(garry.placement = "cost"))

# The cells: an exact NaN mask, exact values, numbers R can use. A kernel that
# computes in f32 against a reference in f64 names a `tolerance`.
.expect_cells <- function(got, want, info = NULL, tolerance = 0) {
  expect_false(inherits(got, "integer64"), info = info)
  expect_true(
    typeof(got) %in% c("double", "integer") || (is.logical(want) && is.logical(got)),
    info = info
  )
  expect_identical(dim(got), dim(want), info = info)
  g <- as.numeric(got)
  w <- as.numeric(want)
  expect_identical(is.nan(g), is.nan(w), info = info)
  expect_identical(is.na(g), is.na(w), info = info)
  expect_equal(g[!is.na(g)], w[!is.na(w)], tolerance = tolerance, info = info)
}

# A file's bands as the (y, x) or (y, x, band) array collect() returns.
.read_cube <- function(path) {
  ds <- suppressWarnings(methods::new(gdalraster::GDALRaster, path, read_only = TRUE))
  withr::defer(ds$close())
  nb <- ds$getRasterCount()
  cube <- suppressWarnings(
    gdal_read_window(path, seq_len(nb), 0L, 0L, ds$getRasterXSize(), ds$getRasterYSize())
  )
  if (nb > 1L) aperm(cube, c(2L, 3L, 1L)) else cube
}

# The most chunks any stage of `x` runs in.
.plan_chunks <- function(x) {
  max(vapply(plan_lazy(x)@stages, function(s) nrow(chunk_iter(s@chunks)), integer(1)))
}

# Plan `x` at a chunk target for the caller's frame; a small one must split it.
.local_px <- function(px, x, env = parent.frame()) {
  withr::local_options(garry.chunk_target_px = px, .local_envir = env)
  if (!is.null(px) && px < 1e4) {
    expect_gt(.plan_chunks(x), 1L)
  }
}

# Run `code` on `leg`, then check the route it took and, for a pooled
# leg, that each chain ran where the placement pass says.
.on_leg <- function(leg, x, code, info = NULL) {
  testthat::local_mocked_bindings(.garry_ram_avail_mb = function() 1e6, .package = "garry")
  tlog <- withr::local_tempfile(fileext = ".csv")
  withr::local_options(leg$opts)
  withr::local_options(garry.task_log = if (!is.null(leg$decision)) tlog)
  out <- suppressWarnings(code)
  expect_identical(garry_last_route(), leg$route, info = info)
  if (!is.null(leg$decision)) {
    tbl <- garry_explain_placement(x)
    if (identical(leg$decision, "none")) {
      expect_identical(nrow(tbl), 0L, info = info)
    } else {
      expect_gt(nrow(tbl), 0L)
      expect_true(all(tbl$decision == leg$decision), info = info)
      keys <- utils::read.csv(tlog)$key
      for (id in tbl$compute) {
        ran <- any(startsWith(keys, paste0("s", id, "_")))
        expect_identical(ran, identical(leg$decision, "comp"), info = info)
      }
    }
  }
  invisible(out)
}

# What a plan returns on each leg of `legs`, in memory and on disk.
#
# x: a lazy raster, or a named list of them (multi-export).
# want: its value from plain R: a matrix, (y, x, band) array or scalar, NaN
#   marking missing cells, logical for a pred raster. A named list for a
#   list `x`.
# dtype: the dtype it must declare and its file must hold. A named vector
#   for a list `x`.
# legs: a list of .leg()s.
# px: garry.chunk_target_px. A small one must really split the plan.
# file: write it too? A file costs a pooled leg about two runs.
# info: extra text for a failure, naming the row of a sweep.
# tolerance: as in .expect_cells(), for the cells in memory.
expect_plan <- function(x, want, dtype, legs = list(.host), px = NULL, file = TRUE, info = NULL,
                        tolerance = 0) {
  .local_px(px, x)
  many <- is.list(want)
  rasters <- if (many) x else list(x)
  wants <- if (many) want else list(want)
  dtypes <- if (many) dtype[names(want)] else dtype
  for (i in seq_along(wants)) {
    expect_identical(rasters[[i]]@grid@dtype, dtypes[[i]], info = info)
  }
  for (leg in legs) {
    got <- .on_leg(leg, x, collect(x, distributed = leg$distributed), info)
    if (!many) {
      got <- list(got)
    }
    for (i in seq_along(wants)) {
      .expect_cells(unclass(got[[i]]), wants[[i]], info, tolerance)
    }
    if (file) {
      .expect_files(x, wants, dtypes, leg, info)
    }
  }
  invisible(x)
}

# Each raster a file can hold, written on `leg`: it reads back as `wants`
# and holds `dtypes`. `...` goes to write_tif(). A scalar is no raster, and a
# predicate has no file dtype, which its write says.
.expect_files <- function(x, wants, held, leg, info = NULL, ...) {
  if (any(held == "pred")) {
    expect_error(
      write_tif(x, tempfile(fileext = ".tif"), distributed = leg$distributed),
      "cannot write dtype"
    )
    return(invisible())
  }
  if (is.null(dim(wants[[1L]]))) {
    return(invisible())
  }
  dir <- withr::local_tempdir()
  paths <- file.path(dir, paste0(if (is.list(x)) names(x) else "x", ".tif"))
  target <- if (is.list(x)) dir else paths
  .on_leg(leg, x, write_tif(x, target, ..., distributed = leg$distributed), info)
  nodata <- list(...)$nodata
  for (i in seq_along(wants)) {
    expect_identical(gdal_grid_spec(paths[[i]])$grid@dtype, held[[i]], info = info)
    .expect_cells(.read_cube(paths[[i]]), wants[[i]], info)
    if (length(nodata)) {
      .expect_sentinel(paths[[i]], wants[[i]], nodata, info)
    }
  }
}

# The file declares `nodata` and stores it in each cell `want` holds as NaN. A
# float file left holding NaN reads back the same, so this reads it unmasked.
.expect_sentinel <- function(path, want, nodata, info = NULL) {
  expect_equal(gdal_grid_spec(path)$nodata, nodata, info = info)
  stored <- .read_cube(garry:::gdal_unmasked_vrt(path))
  expect_true(all(stored[is.nan(want)] == nodata), info = info)
}

# The file a write leaves when it changes what is stored. `want` holds the
# cells as read back, NaN on a written sentinel; `dtype` is the file's, passed
# to write_tif() with `...`. `legs`, `px` and `info` as in expect_plan().
expect_written <- function(x, want, dtype, legs = list(.host), ..., px = NULL, info = NULL) {
  .local_px(px, x)
  wants <- if (is.list(want)) want else list(want)
  for (leg in legs) {
    .expect_files(x, wants, rep(dtype, length(wants)), leg, info, dtype = dtype, ...)
  }
  invisible(x)
}
