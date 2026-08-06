# Grouped collect through multi-export (one plan, one sink per group;
# ir-extensions-todo.md #5): results and written files are identical to
# the legacy per-group loop, ragged groups keep per-group band
# descriptions, {group} paths are unchanged, distributed == single.

skip_if_not_installed("anvl")

.grp_fixture <- function(ragged = FALSE) {
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function(k) lazy_source(f, graph = g) * k
  b04 <- stats::setNames(list(s(1), s(2), s(3), s(4)),
                         c("2024-01-05", "2024-01-20", "2024-02-03",
                           "2024-02-18"))
  b08 <- stats::setNames(list(s(5), s(6), s(7), s(8)),
                         names(b04))
  if (ragged) b08 <- b08[1:2]              # B08 absent from February
  as_dataset(list(B04 = b04, B08 = b08))
}

.legacy_groups <- function(x, path = NULL, nodata = NULL) {
  labels <- names(x@groups)
  paths <- if (is.null(path)) NULL else
    stats::setNames(unlist(garry:::.group_paths(path, labels)), labels)
  res <- lapply(seq_along(x@groups), function(i)
    collect(x@groups[[i]],
            path = if (is.null(paths)) NULL else paths[[i]],
            nodata = nodata, distributed = FALSE))
  names(res) <- labels
  if (!is.null(path)) return(paths)
  res
}

test_that("multi-export grouped collect equals the legacy loop in memory", {
  gr <- .grp_fixture() |> group_by_time("month") |>
    reduce_over("median", over = "t", nan_rm = TRUE)
  new <- collect(gr, distributed = FALSE)
  old <- .legacy_groups(gr)
  expect_identical(names(new), names(old))
  for (nm in names(new))
    expect_equal(new[[nm]], old[[nm]], tolerance = 1e-6)
})

test_that("multi-export grouped writes match legacy files and names", {
  gr <- .grp_fixture(ragged = TRUE) |> group_by_time("month") |>
    reduce_over("median", over = "t", nan_rm = TRUE)
  d1 <- withr::local_tempdir(); d2 <- withr::local_tempdir()
  p_new <- collect(gr, path = file.path(d1, "m-{group}.tif"),
                   distributed = FALSE)
  p_old <- .legacy_groups(gr, path = file.path(d2, "m-{group}.tif"))
  expect_identical(basename(p_new), basename(p_old))
  for (nm in names(p_new)) {
    a <- new(gdalraster::GDALRaster, p_new[[nm]])
    b <- new(gdalraster::GDALRaster, p_old[[nm]])
    expect_identical(a$getRasterCount(), b$getRasterCount())
    expect_identical(
      vapply(seq_len(a$getRasterCount()), function(k) a$getDescription(k), ""),
      vapply(seq_len(b$getRasterCount()), function(k) b$getDescription(k), ""))
    for (k in seq_len(a$getRasterCount()))
      expect_equal(a$read(k, 0, 0, 60, 40, 60, 40),
                   b$read(k, 0, 0, 60, 40, 60, 40), tolerance = 1e-6)
    a$close(); b$close()
  }
  # ragged: February carries only B04
  feb <- new(gdalraster::GDALRaster, p_new[["2024-02"]])
  expect_identical(feb$getRasterCount(), 1L)
  expect_identical(feb$getDescription(1), "B04")
  feb$close()
})

test_that("grouped raw-cube (.vrt) writes work through multi-export", {
  # the materialise-once pattern: day groups are single-slice, so the
  # unreduced dataset writes one raw-BSQ cube per date
  gr <- .grp_fixture() |> group_by_time("day")
  d <- withr::local_tempdir()
  ps <- collect(gr, path = file.path(d, "z-{group}.vrt"),
                distributed = FALSE)
  expect_length(ps, 4L)
  expect_true(all(file.exists(ps)))
  expect_true(all(file.exists(sub("\\.vrt$", ".bin", ps))))
  # readable by GDAL, band descriptions carried, values round-trip
  r <- new(gdalraster::GDALRaster, ps[[1L]])
  expect_identical(r$getRasterCount(), 2L)
  expect_identical(vapply(1:2, function(k) r$getDescription(k), ""),
                   c("B04", "B08"))
  v <- r$read(1, 0, 0, 60, 40, 60, 40)
  r$close()
  ref <- collect(gr@groups[[1L]][["B04"]], distributed = FALSE)
  expect_equal(matrix(v, 40, 60, byrow = TRUE), unclass(ref),
               tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("grouped multi-export: distributed == single-threaded", {
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE), "garry not installed")
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")
  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)
  gr <- .grp_fixture() |> group_by_time("month") |>
    reduce_over("median", over = "t", nan_rm = TRUE)
  d <- collect(gr, distributed = TRUE)
  s <- collect(gr, distributed = FALSE)
  for (nm in names(s)) expect_equal(d[[nm]], s[[nm]], tolerance = 1e-6)
})

test_that("plan_only keeps one plan per group", {
  gr <- .grp_fixture() |> group_by_time("month") |>
    reduce_over("median", over = "t", nan_rm = TRUE)
  ps <- collect(gr, plan_only = TRUE)
  expect_identical(names(ps), c("2024-01", "2024-02"))
  expect_true(all(vapply(ps, function(p) S7::S7_inherits(p, garry::Plan), TRUE)))
})
