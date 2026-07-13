# LazyDataset: the named multi-band, multi-time object whose verbs apply across
# every band. These gates fix that dataset ops equal the hand-written per-band /
# per-slice primitive path (as_dataset + reduce_over + mask vs manual lazy_stack
# + lazy_map), that masking (value-set, qa_bits, morphology) matches a manual
# mask, that indexing/collect assemble the band axis, and that the distributed
# executor reproduces the single-threaded oracle for a full masked composite.

# Two-slice, two-band dataset plus a QA band, all on one shared graph.
ds_fixture <- function(f) {
  g <- graph_new()
  src <- function() lazy_source(f, graph = g)
  as_dataset(
    list(
      V1 = list(s1 = src() * 1, s2 = src() * 2),
      V2 = list(s1 = src() * 3, s2 = src() * 4),
      Q  = list(s1 = src(),     s2 = src() + 1)
    ),
    mask_asset = "Q"
  )
}

test_that("as_dataset builds a named dataset; indexing round-trips", {
  ds <- ds_fixture(fixture_gradient_f32())
  expect_true(S7::S7_inherits(ds, LazyDataset))
  expect_identical(names(ds@bands), c("V1", "V2", "Q"))
  expect_identical(ds@mask_asset, "Q")
  # [[ ]] on a multi-slice band -> a (t, y, x) LazyRaster; [ ] -> sub-dataset
  expect_true(S7::S7_inherits(ds[["V1"]], LazyRaster))
  sub <- ds[c("V1", "V2")]
  expect_true(S7::S7_inherits(sub, LazyDataset))
  expect_identical(names(sub@bands), c("V1", "V2"))
  expect_length(sub@mask_asset, 0L)   # Q not in the subset
})

test_that("reduce_over per band equals the manual stack+reduce path", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  ds <- ds_fixture(f)

  red <- reduce_over(ds, "median", "t")
  expect_true(all(vapply(red@bands, length, 1L) == 1L))  # one composite per band
  out <- collect(red)                                    # (band, y, x)
  expect_equal(dim(out), c(3L, 40L, 60L))

  g <- graph_new()
  s <- function() lazy_source(f, graph = g)
  manual_V1 <- collect(reduce_over(lazy_stack(list(s() * 1, s() * 2)), "median", "t"))
  expect_equal(out[1, , ], manual_V1, tolerance = 1e-6)
})

test_that("collect on a single-band dataset returns a matrix", {
  skip_if_not_installed("anvl")
  ds <- ds_fixture(fixture_gradient_f32())["V1"]
  out <- collect(reduce_over(ds, "mean", "t"))
  expect_equal(dim(out), c(40L, 60L))
})

test_that("mask(qa_bits) equals a manual bitmask + apply", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  ds <- ds_fixture(f)

  masked <- mask(ds, where = qa_bits(0:1))
  expect_false("Q" %in% names(masked@bands))            # QA dropped
  got <- collect(reduce_over(masked, "median", "t"))

  # manual: bad = (value & 3) > 0 with nodata->clear; NaN out the bad pixels
  g <- graph_new()
  s <- function() lazy_source(f, graph = g)
  bad <- function(fv) {
    fc <- g_ifelse(g_is_nodata(fv), 0, fv)
    g_cast(g_bitand(g_cast(fc, "i32"), 3L) > 0, "f32")
  }
  ap <- function(v, b) lazy_map(v, b, fn = function(vv, mm) g_ifelse(mm > 0.5, NaN, vv),
                                dtype = "f32")
  V1s1 <- s() * 1; V1s2 <- s() * 2; Q1 <- s(); Q2 <- s() + 1
  m1 <- ap(V1s1, lazy_map(Q1, fn = bad, dtype = "f32"))
  m2 <- ap(V1s2, lazy_map(Q2, fn = bad, dtype = "f32"))
  manual <- collect(reduce_over(lazy_stack(list(m1, m2)), "median", "t"))
  expect_equal(got[1, , ], manual, tolerance = 1e-6)
})

test_that("mask(value set) flags category membership", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  ds <- ds_fixture(f)

  # values are r*100+c; mask the exact set of QA values present in slice s1 of Q
  # (Q s1 == the raw fixture). Pick a handful of concrete values.
  vals <- c(101, 202, 303)
  got <- collect(reduce_over(mask(ds, where = vals), "median", "t"))

  g <- graph_new()
  s <- function() lazy_source(f, graph = g)
  memb <- function(fv) {
    ind <- lapply(vals, function(v) g_cast(fv == v, "f32"))
    g_cast(Reduce(`+`, ind) > 0, "f32")
  }
  ap <- function(v, b) lazy_map(v, b, fn = function(vv, mm) g_ifelse(mm > 0.5, NaN, vv),
                                dtype = "f32")
  V1s1 <- s() * 1; V1s2 <- s() * 2; Q1 <- s(); Q2 <- s() + 1
  m1 <- ap(V1s1, lazy_map(Q1, fn = memb, dtype = "f32"))
  m2 <- ap(V1s2, lazy_map(Q2, fn = memb, dtype = "f32"))
  manual <- collect(reduce_over(lazy_stack(list(m1, m2)), "median", "t"))
  expect_equal(got[1, , ], manual, tolerance = 1e-6)
})

test_that("mask morphology (open + dilate) matches a manual erode/dilate chain", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  ds <- ds_fixture(f)
  got <- collect(reduce_over(mask(ds, where = qa_bits(0:1), open = 2, dilate = 3),
                             "median", "t"))

  disk <- function(r) { o <- expand.grid(dx = -r:r, dy = -r:r); which(o$dx^2 + o$dy^2 <= r^2) }
  ero  <- function(x, r) { sel <- disk(r); focal(x, radius = as.integer(r),
                                                 fn = function(sh) Reduce(`*`, sh[sel])) }
  dil  <- function(x, r) { sel <- disk(r); focal(x, radius = as.integer(r),
                                                 fn = function(sh) 1 - Reduce(`*`, lapply(sh[sel], function(s) 1 - s))) }
  g <- graph_new()
  s <- function() lazy_source(f, graph = g)
  bad <- function(fv) { fc <- g_ifelse(g_is_nodata(fv), 0, fv); g_cast(g_bitand(g_cast(fc, "i32"), 3L) > 0, "f32") }
  clean <- function(q) dil(dil(ero(lazy_map(q, fn = bad, dtype = "f32"), 2), 2), 3)
  ap <- function(v, b) lazy_map(v, b, fn = function(vv, mm) g_ifelse(mm > 0.5, NaN, vv), dtype = "f32")
  V1s1 <- s() * 1; V1s2 <- s() * 2; Q1 <- s(); Q2 <- s() + 1
  m1 <- ap(V1s1, clean(Q1)); m2 <- ap(V1s2, clean(Q2))
  manual <- collect(reduce_over(lazy_stack(list(m1, m2)), "median", "t"))
  expect_equal(got[1, , ], manual, tolerance = 1e-6)
})

test_that("lazy_map over a dataset skips the mask band; bands= selects", {
  ds <- ds_fixture(fixture_gradient_f32())
  scaled <- lazy_map(ds, fn = function(v) v / 10, dtype = "f32")
  expect_identical(scaled@bands$Q, ds@bands$Q)           # QA untouched
  expect_false(identical(scaled@bands$V1, ds@bands$V1))  # value band changed

  one <- lazy_map(ds, fn = function(v) v / 10, dtype = "f32", bands = "V1")
  expect_false(identical(one@bands$V1, ds@bands$V1))
  expect_identical(one@bands$V2, ds@bands$V2)             # V2 not selected
})

test_that("stack_bands needs one layer per band", {
  ds <- ds_fixture(fixture_gradient_f32())
  expect_error(stack_bands(ds), "one layer per band")
  expect_silent(stack_bands(reduce_over(ds["V1"], "mean", "t")))
})

test_that("scalar arithmetic scales value bands and leaves the mask band", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  ds <- ds_fixture(f)
  scaled <- ds * 0.1
  expect_identical(scaled@bands$Q, ds@bands$Q)           # QA untouched
  got <- collect(reduce_over(scaled["V1"], "mean", "t"))

  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  manual <- collect(reduce_over(lazy_stack(list((s() * 1) * 0.1, (s() * 2) * 0.1)),
                                "mean", "t"))
  expect_equal(got, manual, tolerance = 1e-6)
  expect_true(S7::S7_inherits(100 - ds, LazyDataset))    # scalar-first
})

test_that("dataset + dataset combines shared value bands slice by slice", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  a <- ds_fixture(f)                                      # V1, V2, Q
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  b <- as_dataset(list(V1 = list(s() * 10, s() * 20)))   # only V1 in common

  summed <- a + b
  expect_identical(names(summed@bands), "V1")            # intersection of value bands
  expect_length(summed@mask_asset, 0L)
  got <- collect(reduce_over(summed, "mean", "t"))

  manual <- collect(reduce_over(
    lazy_stack(list(s() * 1 + s() * 10, s() * 2 + s() * 20)), "mean", "t"))
  expect_equal(as.numeric(got), as.numeric(manual), tolerance = 1e-6)
})

test_that("distributed masked composite equals the oracle", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")

  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  old <- options(garry.chunk_target_px = 400)   # force multiple spatial chunks
  on.exit(options(old), add = TRUE)

  f <- fixture_gradient_f32()
  build <- function() reduce_over(mask(ds_fixture(f), where = qa_bits(0:1), dilate = 2),
                                  "median", "t")
  expect_equal(collect(build(), distributed = TRUE),
               collect(build(), distributed = FALSE),
               tolerance = 1e-6)
})
