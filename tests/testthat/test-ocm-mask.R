# P4: the OCM user API. Gates (weights-gated like the golden tests):
# ocm_predict builds the patch graph and executes chunked == whole;
# ocm_mask derives per slice, masks value bands, consumes the class
# band, and preserves slice names; distributed == single-threaded.

skip_if_not_installed("anvl")
skip_if_not_installed("jsonlite")

.ocm_wdir2 <- Sys.getenv("GARRY_OCM_WEIGHTS",
                         path.expand("~/.local/share/omnicloudmask/1.7.1"))

.ocm_toy_model <- function() ocm_model(.ocm_wdir2, models = "regnety",
                                       halo = 32L)

test_that("ocm_predict builds a patch graph and evaluates sanely", {
  skip_if(!dir.exists(.ocm_wdir2), "OCM weights not present")
  m <- .ocm_toy_model()
  f <- fixture_gradient_f32()
  g <- graph_new()
  r <- lazy_source(f, graph = g)
  cls <- ocm_predict(r * 1000, r * 900, r * 2500, model = m)
  expect_identical(names(cls@grid@dims), c("x", "y"))
  out <- execute_plan(plan_lazy(cls))
  expect_identical(dim(out), unname(dim(execute_plan(plan_lazy(r)))))
  expect_true(all(out[is.finite(out)] %in% 0:3))
})

test_that("ocm_predict is chunk-size stable on smooth input", {
  skip_if(!dir.exists(.ocm_wdir2), "OCM weights not present")
  m <- .ocm_toy_model()
  f <- fixture_gradient_f32()
  g <- graph_new()
  r <- lazy_source(f, graph = g)
  cls <- ocm_predict(r * 1000, r * 900, r * 2500, model = m)
  whole <- withr::with_options(list(garry.chunk_target_px = 1e7),
                               execute_plan(plan_lazy(cls)))
  small <- withr::with_options(list(garry.chunk_target_px = 400),
                               execute_plan(plan_lazy(cls)))
  # window-dependent normalisation: agreement, not identity
  expect_gte(mean(small == whole, na.rm = TRUE), 0.98)
})

test_that("ocm_mask masks value bands per slice and keeps names", {
  skip_if(!dir.exists(.ocm_wdir2), "OCM weights not present")
  m <- .ocm_toy_model()
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function(k) lazy_source(f, graph = g) * k
  ds <- as_dataset(list(
    B04 = stats::setNames(list(s(1000), s(1100)), c("2024-01-01", "2024-02-01")),
    B03 = stats::setNames(list(s(900), s(950)),  c("2024-01-01", "2024-02-01")),
    B8A = stats::setNames(list(s(2500), s(2600)), c("2024-01-01", "2024-02-01"))))

  masked <- ocm_mask(ds, red = "B04", green = "B03", nir = "B8A", model = m)
  expect_setequal(names(masked@bands), c("B04", "B03", "B8A"))  # ocm consumed
  expect_identical(names(masked@bands$B04), c("2024-01-01", "2024-02-01"))

  out <- collect(masked[["B04"]], distributed = FALSE)
  raw <- collect(ds[["B04"]], distributed = FALSE)
  expect_identical(dim(out), dim(raw))
  # masked cells are NaN, everything else passes through unchanged
  keep <- is.finite(out)
  expect_equal(out[keep], raw[keep], tolerance = 1e-6)
})

test_that("ocm patch stages: distributed == single-threaded", {
  skip_if(!dir.exists(.ocm_wdir2), "OCM weights not present")
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE), "garry not installed")
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")

  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  m <- .ocm_toy_model()
  f <- fixture_gradient_f32()
  g <- graph_new()
  r <- lazy_source(f, graph = g)
  p <- plan_lazy(ocm_predict(r * 1000, r * 900, r * 2500, model = m))
  d <- execute_plan_mirai(p)
  s <- execute_plan(p)
  expect_identical(is.na(d), is.na(s))
  expect_gte(mean(d == s, na.rm = TRUE), 1)
})

test_that("ocm_model validates and prints", {
  skip_if(!dir.exists(.ocm_wdir2), "OCM weights not present")
  expect_error(ocm_model(.ocm_wdir2, halo = 8L), ">= 32")
  m <- .ocm_toy_model()
  expect_output(print(m), "ocm_model")
  expect_match(m$kernel_id, "^ocm-")
})
