# preview(): the matrix-native render engine (.plot_array) plus the front doors
# (array / file path / lazy object). Rendering gates draw to a throwaway PDF
# device and assert no error; the colour/stretch helpers are checked exactly.

test_that("stretch range: NULL is min/max, percentile clips inward", {
  v <- c(1, 2, 3, NA, 100)
  expect_equal(.pv_range(v, NULL), c(1, 100))
  r <- .pv_range(v, c(2, 98))
  expect_gte(r[[1L]], 1); expect_lt(r[[2L]], 100)     # inside the raw range
})

test_that("normalize clamps to [0,1] and preserves NA", {
  expect_equal(.pv_normalize(c(-5, 0, 5, 10, NA), c(0, 10)),
               c(0, 0, 0.5, 1, NA))
})

test_that("discrete detection: few levels categorical, many continuous", {
  expect_equal(.pv_discrete(c(3, 1, 2, 2, 3)), c(1, 2, 3))
  expect_null(.pv_discrete(1:50))
})

test_that("ramp maps [0,1] to hex; non-finite to NA (transparent)", {
  cols <- .pv_ramp(c("black", "white"))(c(0, 1, NA, NaN, Inf))
  expect_identical(cols[1:2], c("#000000", "#FFFFFF"))
  expect_true(all(is.na(cols[3:5])))
})

test_that(".plot_array renders single / RGB / discrete without error", {
  g <- grid_spec("EPSG:32632", extent = c(0, 0, 60, 40), dims = c(60, 40),
                 dtype = "f32")
  tf <- tempfile(fileext = ".pdf"); grDevices::pdf(tf)
  on.exit({ grDevices::dev.off(); unlink(tf) })
  expect_error(.plot_array(matrix(1:2400 + 0, 40, 60), grid = g, legend = TRUE), NA)
  expect_error(.plot_array(array(seq_len(40 * 60 * 3) + 0, c(40, 60, 3)),
                           grid = g, bands = 1:3), NA)
  expect_error(.plot_array(matrix(sample(1:4, 2400, TRUE), 40, 60), grid = g,
                           legend = TRUE), NA)
  # no grid -> pixel axes still work
  expect_error(.plot_array(matrix(1:2400 + 0, 40, 60)), NA)
})

test_that(".plot_array rejects a band count other than 1 or 3", {
  tf <- tempfile(fileext = ".pdf"); grDevices::pdf(tf)
  on.exit({ grDevices::dev.off(); unlink(tf) })
  expect_error(.plot_array(array(0, c(4, 4, 4)), bands = 1:2), "1 or 3")
})

test_that("preview() dispatches over array, path, and lazy objects", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  ds <- as_dataset(list(a = list(s()), b = list(s() * 2), c = list(s() * 3)))

  tf <- tempfile(fileext = ".pdf"); grDevices::pdf(tf)
  on.exit({ grDevices::dev.off(); unlink(tf) })

  arr <- collect(ds)
  expect_error(preview(arr), NA)                       # collected array
  expect_identical(preview(ds, bands = c("a", "b", "c")), ds)  # names -> RGB, returns x

  out <- tempfile(fileext = ".tif"); collect(ds, path = out, nodata = -9999)
  expect_error(preview(out, bands = 1), NA)            # file path front door
})

test_that("preview() rejects unsupported input", {
  expect_error(preview(list(1, 2, 3)), "LazyRaster")
})
