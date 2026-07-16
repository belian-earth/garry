# ScanNode (iterative axis node): scan_over() carries state along `over`
# while PRESERVING the axis -- the length-keeping sibling of a custom
# reducer. Gates: a cumsum scan matches plain-R apply(cumsum) and its last
# slice equals reduce_over sum; chunked oracle == whole-array (pure R, no
# anvl); reverse and multi-input scans; distributed == single-threaded;
# the grid survives unchanged; distinct scan bodies get distinct kernel
# cache signatures.

.with_chunk_px <- function(px, code) {
  old <- options(garry.chunk_target_px = px)
  on.exit(options(old))
  force(code)
}

cumsum_body <- function(xs, margin) {
  g_scan(
    init = 0,
    body = function(carry, v) {
      s <- carry + v
      list(carry = s, out = s)
    },
    xs = xs[[1L]]
  )$out
}

build_scan_stack <- function(f, body, direction = "forward") {
  a <- lazy_source(f)
  b <- lazy_source(f)
  scan_over(lazy_stack(list(a + 1, b * 2, a * b)), body,
            over = "t", direction = direction)
}

# -- pure-R oracle: chunk-invariance without anvl ------------------------------

test_that("cumsum scan executes identically chunked and whole (oracle)", {
  set.seed(21)
  m1 <- matrix(runif(100 * 100), 100, 100)
  m2 <- matrix(runif(100 * 100), 100, 100)
  data <- list("a.tif" = m1, "b.tif" = m2)

  g <- graph_new()
  a <- lazy_source_stub("a.tif", graph = g)
  b <- lazy_source_stub("b.tif", graph = g)
  sc <- scan_over(lazy_stack(list(a + 1, b * 2)), cumsum_body, over = "t")

  want <- array(NA_real_, c(2, 100, 100))
  want[1, , ] <- m1 + 1
  want[2, , ] <- (m1 + 1) + (m2 * 2)

  for (px in c(17 * 17, 32 * 32, 1e6)) {
    got <- .with_chunk_px(px, {
      oracle_exec(collect(sc, plan_only = TRUE), data)
    })
    expect_equal(got, want, tolerance = 1e-12)
  }
})

test_that("reverse scan writes at original positions (oracle)", {
  set.seed(22)
  m <- matrix(runif(100 * 100), 100, 100)   # stub grids are fixed 100x100
  data <- list("x.tif" = m)

  g <- graph_new()
  a <- lazy_source_stub("x.tif", graph = g)
  rev_body <- function(xs, margin) {
    g_scan(
      init = 0,
      body = function(carry, v) {
        s <- carry + v
        list(carry = s, out = s)
      },
      xs = xs[[1L]],
      reverse = TRUE
    )$out
  }
  sc <- scan_over(lazy_stack(list(a, a * 2, a * 3)), rev_body,
                  over = "t", direction = "backward")

  # reverse cumsum: slice t holds the sum of slices t..T
  want <- array(NA_real_, c(3, 100, 100))
  want[3, , ] <- m * 3
  want[2, , ] <- m * 2 + m * 3
  want[1, , ] <- m + m * 2 + m * 3

  got <- .with_chunk_px(23 * 23, {
    oracle_exec(collect(sc, plan_only = TRUE), data)
  })
  expect_equal(got, want, tolerance = 1e-12)
})

# -- traced path (anvl): scan_over through execute_plan ------------------------

test_that("cumsum scan matches apply() and its last slice the reduce", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  sc <- build_scan_stack(f, cumsum_body)
  out <- execute_plan(plan_lazy(sc))

  a <- lazy_source(f)
  b <- lazy_source(f)
  stk <- execute_plan(plan_lazy(lazy_stack(list(a + 1, b * 2, a * b))))
  expect_equal(out, apply(stk, c(2, 3), cumsum), tolerance = 1e-5)

  red <- execute_plan(plan_lazy(
    reduce_over(lazy_stack(list(a + 1, b * 2, a * b)), "sum", "t")))
  expect_equal(out[3, , ], red, tolerance = 1e-5)
})

test_that("a multi-input scan reads parent cubes in lockstep", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  b <- lazy_source(f)
  s1 <- lazy_stack(list(a + 1, a + 2))
  s2 <- lazy_stack(list(b * 2, b * 3))
  pair_body <- function(xs, margin) {
    g_scan(
      init = 0,
      body = function(carry, v) {
        s <- carry + v$p * v$q
        list(carry = s, out = s)
      },
      xs = list(p = xs[[1L]], q = xs[[2L]])
    )$out
  }
  out <- execute_plan(plan_lazy(scan_over(list(s1, s2), pair_body)))

  v1 <- execute_plan(plan_lazy(s1))
  v2 <- execute_plan(plan_lazy(s2))
  want <- v1 * v2
  want[2, , ] <- want[1, , ] + want[2, , ]
  expect_equal(out, want, tolerance = 1e-5)
})

test_that("a scan body can compute in f64 internally and emit f32", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  f64_body <- function(xs, margin) {
    x <- g_cast(xs[[1L]], "f64")
    out <- g_scan(
      init = 0,
      body = function(carry, v) {
        s <- carry + v
        list(carry = s, out = s)
      },
      xs = x
    )$out
    g_cast(out, "f32")
  }
  got <- execute_plan(plan_lazy(build_scan_stack(f, f64_body)))
  ref <- execute_plan(plan_lazy(build_scan_stack(f, cumsum_body)))
  expect_equal(got, ref, tolerance = 1e-6)
})

test_that("scan: distributed == single-threaded", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE), "garry not installed")
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")
  skip_if(!garry::.g_has_nv_scan(), "installed anvl lacks nv_scan")

  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  old <- options(garry.chunk_target_px = 400)   # force many spatial chunks
  on.exit(options(old), add = TRUE)

  f <- fixture_gradient_f32()
  p <- plan_lazy(build_scan_stack(f, cumsum_body))
  expect_equal(execute_plan_mirai(p), execute_plan(p), tolerance = 1e-6)
})

# -- dataset dispatch ----------------------------------------------------------

test_that("scan_over a LazyDataset scans each band's t-stack", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  g <- graph_new()
  src <- function() lazy_source(f, graph = g)
  ds <- as_dataset(list(
    V1 = list(s1 = src() * 1, s2 = src() * 2),
    V2 = list(s1 = src() * 3, s2 = src() * 4)
  ))
  sc <- scan_over(ds, cumsum_body, over = "t")
  expect_true(S7::S7_inherits(sc, LazyDataset))
  got <- execute_plan(plan_lazy(sc[["V2"]]))

  m <- execute_plan(plan_lazy(src()))
  want <- array(NA_real_, c(2, dim(m)))
  want[1, , ] <- m * 3
  want[2, , ] <- m * 3 + m * 4
  expect_equal(got, want, tolerance = 1e-5)
})

# -- IR contracts ---------------------------------------------------------------

test_that("scan preserves the grid; dtype override retypes only", {
  g <- graph_new()
  a <- lazy_source_stub("a.tif", graph = g)
  b <- lazy_source_stub("b.tif", graph = g)
  stk <- lazy_stack(list(a, b))
  sc <- scan_over(stk, cumsum_body, over = "t")
  expect_identical(sc@grid, stk@grid)

  sc64 <- scan_over(stk, cumsum_body, over = "t", dtype = "f64")
  expect_identical(sc64@grid@dtype, "f64")
  expect_identical(sc64@grid@dims, stk@grid@dims)
  expect_identical(sc64@grid@transform, stk@grid@transform)
})

test_that("scan_over rejects spatial axes, bad grids, bad direction", {
  g <- graph_new()
  a <- lazy_source_stub("a.tif", graph = g)
  b <- lazy_source_stub("b.tif", graph = g)
  stk <- lazy_stack(list(a, b))

  expect_error(scan_over(stk, cumsum_body, over = "x"), "spatial")
  expect_error(scan_over(stk, cumsum_body, over = "nope"), "must name one dim")
  expect_error(scan_over(stk, cumsum_body, direction = "sideways"),
               "forward, backward, bidir")
  # mixed grids: a (t, y, x) stack and a 2-D raster
  expect_error(scan_over(list(stk, a), cumsum_body), "share one grid")
})

test_that("scan is a planner barrier with zero halo, full axis per chunk", {
  g <- graph_new()
  a <- lazy_source_stub("a.tif", graph = g)
  b <- lazy_source_stub("b.tif", graph = g)
  sc <- scan_over(lazy_stack(list(a, b)), cumsum_body, over = "t")
  node <- graph_get(sc@graph, sc@node_id)
  expect_true(is_barrier(node))
  expect_identical(required_halo(node), 0L)

  # the scan joins a compute stage chunked over space only
  p <- .with_chunk_px(17 * 17, collect(sc, plan_only = TRUE))
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  cid <- which(vapply(p@stages, function(s)
    s@kind == "compute" && sc@node_id %in% s@members, logical(1)))
  expect_length(cid, 1L)
  it <- chunk_iter(p@stages[[cid]]@chunks)
  expect_gt(nrow(it), 1L)   # spatially tiled; t rides whole in every chunk
})

test_that("distinct scan bodies get distinct kernel signatures", {
  g <- graph_new()
  a <- lazy_source_stub("a.tif", graph = g)
  b <- lazy_source_stub("b.tif", graph = g)
  mk <- function(body) {
    sc <- scan_over(lazy_stack(list(a, b)), body, over = "t")
    p <- collect(sc, plan_only = TRUE)
    cid <- which(vapply(p@stages, function(s)
      s@kind == "compute" && sc@node_id %in% s@members, logical(1)))
    garry:::.stage_kernel_sig(p@graph, p@stages[[cid]])
  }
  other_body <- function(xs, margin) {
    g_scan(
      init = 0,
      body = function(carry, v) {
        s <- carry + v * 2
        list(carry = s, out = s)
      },
      xs = xs[[1L]]
    )$out
  }
  expect_false(identical(mk(cumsum_body), mk(other_body)))
})

test_that("distinct custom reducers get distinct kernel signatures", {
  # regression: the ReduceNode cache key used to omit the custom fn
  g <- graph_new()
  a <- lazy_source_stub("a.tif", graph = g)
  b <- lazy_source_stub("b.tif", graph = g)
  mk <- function(fn) {
    rd <- reduce_over(lazy_stack(list(a, b)), fn, "t")
    p <- collect(rd, plan_only = TRUE)
    cid <- which(vapply(p@stages, function(s)
      s@kind == "compute" && rd@node_id %in% s@members, logical(1)))
    garry:::.stage_kernel_sig(p@graph, p@stages[[cid]])
  }
  f1 <- function(x, dims) g_sum(x, dims = dims, nan_rm = TRUE)
  f2 <- function(x, dims) g_max(x, dims = dims, nan_rm = TRUE)
  expect_false(identical(mk(f1), mk(f2)))
})
