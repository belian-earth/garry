# Decision D10 lock, part 2: executing the golden plans chunk-by-chunk
# through the pure-R oracle equals whole-array computation. This is the
# chunking-correctness proof independent of anvl.

.with_chunk_px <- function(px, code) {
  old <- options(garry.chunk_target_px = px)
  on.exit(options(old))
  force(code)
}

test_that("NDVI executes identically chunked and whole", {
  set.seed(10)
  nir <- matrix(runif(100 * 100, 0.2, 0.6), 100, 100)
  red <- matrix(runif(100 * 100, 0.05, 0.3), 100, 100)
  data <- list("nir.tif" = nir, "red.tif" = red)
  want <- (nir - red) / (nir + red)

  a <- lazy_source_stub("nir.tif")
  b <- lazy_source_stub("red.tif")
  ndvi <- (a - b) / (a + b)

  for (px in c(17 * 17, 32 * 32, 64 * 48, 1e6)) {
    got <- .with_chunk_px(px, {
      oracle_exec(collect(ndvi, plan_only = TRUE), data)
    })
    expect_equal(got, want, tolerance = 1e-12)
  }
})

test_that("map -> focal -> global mean executes identically chunked", {
  set.seed(11)
  m <- matrix(runif(100 * 100), 100, 100)
  data <- list("x.tif" = m)

  # Reference: +1, 3x3 mean with NaN boundary, then mean ignoring NaN.
  mp <- m + 1
  padded <- matrix(NaN, 102, 102)
  padded[2:101, 2:101] <- mp
  conv <- matrix(0, 100, 100)
  for (dy in 0:2) for (dx in 0:2)
    conv <- conv + padded[(1 + dy):(100 + dy), (1 + dx):(100 + dx)]
  conv <- conv / 9                       # NaN ring at the edges
  want <- mean(conv, na.rm = TRUE)

  a <- lazy_source_stub("x.tif")
  f <- focal(a + 1, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)
  r <- reduce_over(f, "mean", c("x", "y"), nan_rm = TRUE)

  for (px in c(17 * 17, 23 * 23, 1e6)) {
    got <- .with_chunk_px(px, {
      oracle_exec(collect(r, plan_only = TRUE), data)
    })
    expect_equal(got, want, tolerance = 1e-12)
  }
})

test_that("stacked focals execute identically chunked (halo 3)", {
  set.seed(12)
  m <- matrix(runif(100 * 100), 100, 100)   # stub grid is 100x100
  data <- list("x.tif" = m)

  sum9 <- function(sh) Reduce(`+`, sh)
  a <- lazy_source_stub("x.tif")
  f2 <- focal(focal(a, sum9, 1L), sum9, 2L)

  ref1 <- {
    p <- matrix(NaN, 102, 102); p[2:101, 2:101] <- m
    o <- matrix(0, 100, 100)
    for (dy in 0:2) for (dx in 0:2)
      o <- o + p[(1 + dy):(100 + dy), (1 + dx):(100 + dx)]
    o
  }
  ref2 <- {
    p <- matrix(NaN, 104, 104); p[3:102, 3:102] <- ref1
    o <- matrix(0, 100, 100)
    for (dy in 0:4) for (dx in 0:4)
      o <- o + p[(1 + dy):(100 + dy), (1 + dx):(100 + dx)]
    o
  }

  for (px in c(19 * 19, 1e6)) {
    got <- .with_chunk_px(px, {
      oracle_exec(collect(f2, plan_only = TRUE), data)
    })
    expect_equal(got, ref2, tolerance = 1e-12)
  }
})

test_that("global min/max/sum/count reduce correctly across chunks", {
  set.seed(13)
  m <- matrix(runif(100 * 100), 100, 100)
  m[sample(length(m), 500)] <- NaN
  data <- list("x.tif" = m)
  a <- lazy_source_stub("x.tif")

  cases <- list(
    list(op = "sum",   want = sum(m, na.rm = TRUE)),
    list(op = "min",   want = min(m, na.rm = TRUE)),
    list(op = "max",   want = max(m, na.rm = TRUE)),
    list(op = "count", want = sum(!is.nan(m))),
    list(op = "mean",  want = mean(m, na.rm = TRUE))
  )
  for (cs in cases) {
    r <- reduce_over(a, cs$op, c("x", "y"), nan_rm = TRUE)
    got <- .with_chunk_px(29 * 29, {
      oracle_exec(collect(r, plan_only = TRUE), data)
    })
    expect_equal(got, cs$want, tolerance = 1e-12, label = cs$op)
  }
})
