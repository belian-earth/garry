# Base-R accessors on lazy objects: dim() matches collect(); names(),
# length() and $ / $<- on datasets; time_labels().

test_that("dim() is the shape collect() returns", {
  r <- lazy_source(fixture_gradient_f32())
  expect_identical(unname(dim(r)), dim(collect(r)))
  expect_named(dim(r), c("y", "x"))
  s <- lazy_stack(list(r, r * 2, r * 3), along = "t")
  expect_identical(unname(dim(s)), dim(collect(s)))
  expect_named(dim(s), c("y", "x", "t"))
  g <- grid_spec(extent = c(0, 0, 100, 50), res = 10, crs = "EPSG:3857")
  expect_identical(dim(g), c(y = 5L, x = 10L))
})

test_that("names(), length() and $ / $<- work on a dataset", {
  r <- lazy_source(fixture_gradient_f32())
  ds <- as_dataset(list(a = r, b = r * 2))
  expect_identical(names(ds), c("a", "b"))
  expect_identical(length(ds), 2L)
  expect_identical(collect(ds$b), collect(ds[["b"]]))
  ds$c <- ds$a + ds$b
  expect_identical(names(ds), c("a", "b", "c"))
  expect_equal(collect(ds$c), 3 * collect(r))
})

test_that("time_labels() reads the t axis of rasters and datasets", {
  f <- fixture_gradient_f32()
  g <- graph_new()
  src <- function() lazy_source(f, graph = g)
  ds <- as_dataset(
    list(
      V1 = list(s1 = src(), s2 = src() * 2),
      Q = list(s1 = src(), s2 = src())
    ),
    mask_asset = "Q"
  )
  expect_identical(time_labels(ds), c("s1", "s2"))
  expect_identical(time_labels(ds$V1), c("s1", "s2"))
  expect_null(time_labels(lazy_source(f)))
  expect_null(time_labels(as_dataset(list(a = lazy_source(f)))))
})
