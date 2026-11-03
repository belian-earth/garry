# The edge ring inside a stage. A stage's inputs carry NaN past the raster, and
# a member computes those cells too, so a NaN-ignoring window, a NaN-filling
# map, an integer cast or a count can leave real-looking values there. A window
# over a member reads them back at nodata, as it would across a stage boundary.
# Every answer here is that of chained windows in plain R, each finding NaN
# past the raster.

.er_nx <- 11L
.er_ny <- 9L
.er_a <- local({
  set.seed(7)
  matrix(as.numeric(sample(900L, .er_nx * .er_ny, TRUE)), .er_ny, .er_nx)
})
.er_tile <- function(m, ...) {
  fixture_tile(t(m), ..., nx = ncol(m), ny = nrow(m), gt = c(0, 10, 0, 10 * nrow(m), 0, -10))
}

# A window of radius `r` over `a`, `f` taking the cells it covers.
.er_win <- function(a, r, f) {
  p <- matrix(NaN, nrow(a) + 2L * r, ncol(a) + 2L * r)
  p[r + seq_len(nrow(a)), r + seq_len(ncol(a))] <- a
  out <- a
  for (i in seq_len(nrow(a))) {
    for (j in seq_len(ncol(a))) {
      out[i, j] <- f(p[i:(i + 2L * r), j:(j + 2L * r)])
    }
  }
  out
}
.er_mean_ok <- function(v) mean(v[!is.nan(v)])

# The same in the kernels: a sum, NaN once any cell is, and a mean ignoring NaN.
.er_sum <- function(sh) Reduce(`+`, sh)
.er_mean <- function(sh) {
  n <- Reduce(`+`, lapply(sh, function(s) g_ifelse(g_is_nodata(s), 0, 1)))
  Reduce(`+`, lapply(sh, function(s) g_ifelse(g_is_nodata(s), 0, s))) / n
}
.er_fill <- function(v) g_ifelse(g_is_nodata(v), 0, v)
.er_cast <- function(v) g_cast(v, "i32")

# One chain over any 2-D source `x`, and its answer over that source's cells.
.er_chains <- list(
  `NaN-ignoring window, window` = list(
    x = function(x) focal_map(focal_map(x, .er_mean, 1L), .er_sum, 1L),
    want = function(a) .er_win(.er_win(a, 1L, .er_mean_ok), 1L, sum)
  ),
  `NaN-filling map, window` = list(
    x = function(x) focal_map(lazy_map(x, fn = .er_fill), .er_sum, 1L),
    want = function(a) .er_win(ifelse(is.nan(a), 0, a), 1L, sum)
  ),
  `integer cast map, window` = list(
    x = function(x) focal_map(lazy_map(x, fn = .er_cast), .er_sum, 1L),
    want = function(a) .er_win(a, 1L, sum),
    dtype = "f64"
  ),
  `window, map, window` = list(
    x = function(x) {
      focal_map(lazy_map(focal_map(x, .er_mean, 1L), fn = function(v) v * 2), .er_sum, 1L)
    },
    want = function(a) .er_win(.er_win(a, 1L, .er_mean_ok) * 2, 1L, sum)
  ),
  `three windows` = list(
    x = function(x) {
      focal_map(focal_map(focal_map(x, .er_mean, 1L), .er_mean, 1L), .er_sum, 1L)
    },
    want = function(a) .er_win(.er_win(.er_win(a, 1L, .er_mean_ok), 1L, .er_mean_ok), 1L, sum)
  ),
  `radii 2 then 1` = list(
    x = function(x) focal_map(focal_map(x, .er_mean, 2L), .er_sum, 1L),
    want = function(a) .er_win(.er_win(a, 2L, .er_mean_ok), 1L, sum)
  ),
  `radii 1 then 2` = list(
    x = function(x) focal_map(focal_map(x, .er_mean, 1L), .er_mean, 2L),
    want = function(a) .er_win(.er_win(a, 1L, .er_mean_ok), 2L, .er_mean_ok)
  )
)

# Chunks smaller than the pad the deepest chain carries: 2 x 2 under a pad of 3.
.er_px <- 4
.er_tol <- 2e-5

test_that("the ring is counted per side, at any distance from the edge", {
  gd <- c(x = 17L, y = 13L)
  core <- function(x_off, y_off, x_size = 2L, y_size = 2L) {
    data.frame(x_off = x_off, y_off = y_off, x_size = x_size, y_size = y_size)
  }
  expect_identical(.ring_cells(core(6L, 6L), gd, 3L), rep(0L, 4L))
  expect_identical(.ring_cells(core(0L, 0L), gd, 3L), c(3L, 3L, 0L, 0L))
  # one in from the edge, a chunk smaller than the pad reaches past it by less
  expect_identical(.ring_cells(core(2L, 2L), gd, 3L), c(1L, 1L, 0L, 0L))
  expect_identical(.ring_cells(core(14L, 10L), gd, 3L), c(0L, 0L, 2L, 2L))
  # an edge chunk's grown cells lie past the raster too
  expect_identical(.ring_cells(core(16L, 12L, 1L, 1L), gd, 3L, c(1L, 1L)), c(0L, 0L, 4L, 4L))
  expect_identical(.ring_cells(core(16L, 12L, 1L, 1L), gd, 0L, c(1L, 1L)), c(0L, 0L, 1L, 1L))
})

test_that("a kernel masks what a stage boundary masks", {
  ring <- c(1L, 2L, 3L, 0L)
  dtypes <- c(f32 = "f32", i16 = "i16", u8 = "u8")
  for (cube in c(FALSE, TRUE)) {
    a <- if (cube) array(1:48 + 0, c(2L, 4L, 6L)) else matrix(1:24 + 0, 4L, 6L)
    for (dt in dtypes) {
      jf <- g_jit(function(inp) list(.g_mask_ring(inp[[1L]], inp[[2L]], 1L, dt)))
      got <- g_download(jf(list(g_upload(a, dt), g_upload(ring, "i32"))))[[1L]]
      # a value one cell in from the padded input loses one cell of each side
      expect_equal(unclass(got), .mask_cells(a, c(0L, 1L, 2L, 0L), dt), info = dt)
      expect_equal(.g_mask_ring(a, ring, 1L, dt), .mask_cells(a, c(0L, 1L, 2L, 0L), dt))
    }
  }
})

test_that("only a window over a member takes the ring", {
  x <- lazy_source(.er_tile(.er_a))
  plain <- plan_lazy(focal_map(x, .er_sum, 1L) * 2)
  chain <- plan_lazy(focal_map(focal_map(x, .er_sum, 1L), .er_sum, 1L))
  stage <- function(p) Find(function(s) s@kind == "compute", p@stages)
  expect_false(.takes_ring(plain@graph, stage(plain)))
  s <- stage(chain)
  expect_true(.takes_ring(chain@graph, s))
  # the window over the source reads what the read left
  expect_identical(.ring_windows(chain@graph, s@members, s@input_nodes), s@members[[2L]])
})

test_that("a stage without a window over a member keeps its kernel and inputs", {
  x <- lazy_source(.er_tile(.er_a))
  p <- plan_lazy(focal_map(x, function(sh) sh[[1L]], 1L) * 2)
  s <- Find(function(s) s@kind == "compute", p@stages)
  sig <- .stage_kernel_sig(p@graph, s)
  # a literal, so a change to what a signature hashes shows here
  expect_identical(sig, "k469f90699644a234911f700c8cc607a8")
  meta <- .exec_in_meta(p@graph, s, p@stages)
  pg <- .stage_as_program(p@graph, s, sig, meta, 1L, FALSE)
  expect_identical(names(pg$set), "f32:11x13")
  # a chunk's arrays alone run it
  expect_length(s@fn(list(matrix(1, 11L, 13L))), 1L)
})

test_that("a ring kernel lists its ring as an input of every shape", {
  x <- lazy_source(.er_tile(.er_a))
  p <- plan_lazy(focal_map(focal_map(x, .er_sum, 1L), .er_sum, 1L))
  s <- Find(function(s) s@kind == "compute", p@stages)
  pg <- .stage_as_program(p@graph, s, "k", .exec_in_meta(p@graph, s, p@stages), 2L, FALSE)
  expect_true(all(grepl(",i32:4$", names(pg$set))))
})

test_that("a warm-up runs a kernel that takes the ring", {
  e <- .local_kernel_cache()
  x <- lazy_source(.er_tile(.er_a))
  p <- plan_lazy(focal_map(focal_map(x, .er_sum, 1L), .er_sum, 1L))
  s <- Find(function(s) s@kind == "compute", p@stages)
  sp <- list(
    ck = "ring", device = "cpu", fn = s@fn, dtypes = "f32", outers = 1L,
    nr = .er_ny + 4L, nc = .er_nx + 4L, ring = TRUE
  )
  expect_no_error(.daemon_warm_jit(list(sp)))
  expect_identical(ls(e, all.names = TRUE), "ring")
})

test_that("morphology takes one select per window, not one per disk offset", {
  q <- matrix(1, .er_ny, .er_nx)
  g <- graph_new()
  ds <- as_dataset(list(V = lazy_source(.er_tile(.er_a), graph = g),
                        Q = lazy_source(.er_tile(q), graph = g)), mask_asset = "Q")
  p <- plan_lazy(apply_mask(ds, where = 2, open = 1L, dilate = 1L)@bands$V[[1L]])
  s <- Find(function(s) s@kind == "compute" && length(s@members) > 1L, p@stages)
  windows <- .ring_windows(p@graph, s@members, s@input_nodes)
  expect_length(windows, 3L)
  pg <- .stage_as_program(p@graph, s, "k", .exec_in_meta(p@graph, s, p@stages),
                          s@halo + s@out_pad, FALSE)
  src <- unclass(pg$set)[[1L]]$src
  expect_length(gregexpr("stablehlo.select", src, fixed = TRUE)[[1L]], length(windows))
})

test_that("a fused chain taking the ring never tiles", {
  x <- lazy_source(.er_tile(.er_a))
  p <- plan_lazy(focal_map(focal_map(x, .er_sum, 1L), .er_sum, 1L))
  s <- Find(function(s) s@kind == "compute", p@stages)
  withr::local_options(garry.ram_budget_mb = 1e-6)
  expect_identical(.fuse_tiles(p@graph, s, 1e6, 1000, 1L)$tiles, 1L)
})

test_that("the gradient tape keeps a ring from any valid cell", {
  # Its validity mask carries every cell past the raster through a map that
  # fills NaN, so a loss sums only cells whose windows lie on the raster.
  k <- matrix(c(0, 1, 0, 1, 2, 1, 0, 1, 0) / 6, 3L, 3L)
  x <- lazy_source(.er_tile(.er_a))
  inner <- focal_kernel(x, k)
  outer <- focal_kernel(lazy_map(inner, fn = .er_fill), k)
  loss <- reduce_over(outer, "sum", c("x", "y"))
  got <- lazy_value_and_grad(loss, inner)
  conv <- function(a) .er_win(a, 1L, function(v) sum(v * k))
  want <- conv(conv(.er_a))
  expect_equal(got$value, sum(want, na.rm = TRUE), tolerance = 1e-5)
  expect_identical(sum(is.nan(want)), .er_nx * .er_ny - (.er_nx - 4L) * (.er_ny - 4L))
})

test_that("a patch over an integer raster finds NaN past the edge, not 0", {
  left <- function(v) {
    n <- length(.g_shape(v))
    s <- g_shift_slice(v, 0L, -1L, .g_shape(v)[[n - 1L]] - 2L, .g_shape(v)[[n]] - 2L, 1L)
    g_pad(s, 1L, 0)
  }
  x <- lazy_source(fixture_tile(5, type = "Int16", nx = 6L, ny = 4L))
  want <- matrix(5, 4L, 6L)
  want[, 1L] <- NaN
  expect_equal(collect(lazy_patch(x, left, radius = 1L, kernel_id = "left")), want, ignore_attr = TRUE)
})

test_that("the gradient tape finds the ring past a decode of an integer read", {
  # An integer read holds 0 past the raster, which no validity mask can tell
  # from data, so the tape takes where the raster ends, as a stage does.
  k <- matrix(c(0, 1, 0, 1, 2, 1, 0, 1, 0) / 6, 3L, 3L)
  f <- .er_tile(.er_a, type = "Int16")
  bits <- .er_a %% 2
  conv <- function(w) .er_win(bits, 1L, function(v) sum(v * w))
  grad <- matrix(0, 3L, 3L)
  for (i in seq_along(grad)) {
    grad[[i]] <- sum(conv(replace(k, i, k[[i]] + 1)) - conv(k), na.rm = TRUE)
  }
  for (px in list(NULL, 16)) {
    withr::local_options(garry.chunk_target_px = px)
    decoded <- lazy_map(lazy_source(f), dtype = "f32",
                        fn = function(v) g_cast(g_bitand(v, 1L), "f32"))
    fk <- focal_kernel(decoded, k)
    sum_loss <- reduce_over(fk, "sum", c("x", "y"))
    got <- lazy_value_and_grad(sum_loss, fk)
    expect_equal(got$value, sum(conv(k), na.rm = TRUE), tolerance = 1e-5)
    expect_equal(got$grad, grad, tolerance = 1e-5)
    expect_equal(got$value, as.numeric(collect(sum_loss, distributed = FALSE)), tolerance = 1e-5)
    mean_loss <- reduce_over(fk, "mean", c("x", "y"))
    expect_equal(lazy_value_and_grad(mean_loss, fk)$value, mean(conv(k), na.rm = TRUE),
                 tolerance = 1e-5)
  }
})

local({
  local_pools(2, 1)

  # the fused path hangs on macOS: test-compute-on-read.R
  fused <- if (Sys.info()[["sysname"]] != "Darwin") list(.fused)
  legs <- c(list(.host, .comp), fused)
  # a wide kernel stays off a reader with no thread cap, and only Linux caps them
  wide <- c(list(.host, .comp), if (!is.null(.garry_state$reader_threads)) fused)
  closure <- list(
    .leg(decision = "comp", opts = list(garry.placement = "rules", garry.kernel_wire = "closure"))
  )
  if (length(fused)) {
    closure <- c(closure, list(
      .leg(decision = "fuse", opts = list(garry.placement = "cost", garry.kernel_wire = "closure"))
    ))
  }

  test_that("a chain inside a stage equals plain R, on chunks smaller than its pad", {
    x <- lazy_source(.er_tile(.er_a))
    for (nm in names(.er_chains)) {
      ch <- .er_chains[[nm]]
      r <- ch$x(x)
      want <- ch$want(.er_a)
      dt <- ch$dtype %||% "f32"
      expect_plan(r, want, dt, file = FALSE, info = nm, tolerance = .er_tol)
      expect_plan(r, want, dt, legs = legs, px = .er_px, file = FALSE, info = nm,
                  tolerance = .er_tol)
    }
    # three windows pad a chunk by more than its size, and the read a fused
    # kernel runs on tiles coarser than the chunks
    p <- .with_chunk_px(.er_px, plan_lazy(.er_chains[[5L]]$x(x)))
    expect_gt(p@stages[[2L]]@halo, max(p@stages[[2L]]@chunks@chunk_dim))
    expect_gt(prod(p@stages[[1L]]@chunks@chunk_dim), prod(p@stages[[2L]]@chunks@chunk_dim))
  })

  test_that("a grown chunk gives the answer of an ungrown one", {
    x <- lazy_source(.er_tile(.er_a))
    withr::local_options(garry.pad_edge_chunks = FALSE)
    for (nm in names(.er_chains)[c(1L, 7L)]) {
      ch <- .er_chains[[nm]]
      expect_plan(ch$x(x), ch$want(.er_a), ch$dtype %||% "f32", legs = c(list(.host), fused),
                  px = .er_px, file = FALSE, info = nm, tolerance = .er_tol)
    }
  })

  test_that("a fused kernel over small read windows finds where the raster ends", {
    skip_on_os("mac") # the fused path hangs there: test-compute-on-read.R
    # Full-width read strips, the last one short, so one kernel runs windows at
    # three distances from the edge, the short one grown to the others' shape.
    withr::local_options(garry.read_target_px = 16)
    x <- lazy_source(.er_tile(.er_a))
    for (grow in c(TRUE, FALSE)) {
      withr::local_options(garry.pad_edge_chunks = grow)
      for (nm in names(.er_chains)[c(1L, 5L, 7L)]) {
        ch <- .er_chains[[nm]]
        expect_plan(ch$x(x), ch$want(.er_a), "f32", legs = list(.fused), px = .er_px, file = FALSE,
                    info = paste(nm, grow), tolerance = .er_tol)
      }
    }
    p <- .with_chunk_px(.er_px, plan_lazy(.er_chains[[1L]]$x(x)))
    expect_identical(chunk_iter(p@stages[[1L]]@chunks)$y_size, c(2L, 2L, 2L, 2L, 1L))
  })

  test_that("a closure kernel takes the ring as a program does", {
    x <- lazy_source(.er_tile(.er_a))
    ch <- .er_chains[[1L]]
    expect_plan(ch$x(x), ch$want(.er_a), "f32", legs = closure, px = .er_px, file = FALSE,
                tolerance = .er_tol)
  })

  test_that("a stage that computes a ring of its own masks at its padded inputs", {
    # Windows over a stack of chains: each chain's stage carries a ring out to
    # the stack, so its inputs arrive padded past its own halo. A chain over one
    # source fuses, and a chain over two runs on compute tasks.
    g <- graph_new()
    src <- function(k) lazy_source(.er_tile(.er_a * k), graph = g)
    one <- function(k) focal_map(lazy_map(src(k), fn = .er_fill), .er_sum, 1L)
    two <- function(k) {
      focal_map(lazy_map(src(k), src(k + 1), fn = function(a, b) .er_fill(a + b)), .er_sum, 1L)
    }
    over <- function(a, b) focal_map(lazy_stack(list(a, b), along = "band"), .er_sum, 1L)
    fused_chains <- over(one(1), one(2))
    task_chains <- over(two(1), two(3))
    for (r in list(fused_chains, task_chains)) {
      p <- plan_lazy(r)
      takes <- Filter(function(s) s@kind == "compute" && .takes_ring(p@graph, s), p@stages)
      expect_gt(max(vapply(takes, function(s) s@out_pad, 1L)), 0L)
    }
    twice <- function(k) .er_win(.er_win(.er_a * k, 1L, sum), 1L, sum)
    bands <- function(a, b) array(c(a, b), c(.er_ny, .er_nx, 2L))
    expect_plan(fused_chains, bands(twice(1), twice(2)), "f32", legs = c(list(.host), fused),
                px = .er_px, file = FALSE)
    expect_plan(task_chains, bands(twice(3), twice(7)), "f32", px = .er_px, file = FALSE,
                legs = list(.host, .leg(decision = "none")))
  })

  test_that("a window over a member of a band cube reads a coalesced read's ring", {
    # both bands of one file, read together and fused on the read
    f <- tempfile(fileext = ".tif")
    d <- gdalraster::create("GTiff", f, .er_nx, .er_ny, 2L, "Float32", return_obj = TRUE)
    d$setGeoTransform(c(0, 10, 0, 10 * .er_ny, 0, -10))
    d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    d$write(1L, 0L, 0L, .er_nx, .er_ny, as.numeric(t(.er_a)))
    d$write(2L, 0L, 0L, .er_nx, .er_ny, as.numeric(t(.er_a * 2)))
    d$close()
    g <- graph_new()
    x <- lazy_stack(lapply(1:2, function(b) lazy_source(f, band = b, graph = g)), along = "band")
    r <- focal_map(lazy_map(x, fn = .er_fill), .er_sum, 1L)
    expect_identical(length(graph_get(r@graph, plan_lazy(r)@stages[[1L]]@members[[1L]])@band), 2L)
    want <- array(c(.er_win(.er_a, 1L, sum), .er_win(.er_a * 2, 1L, sum)), c(.er_ny, .er_nx, 2L))
    expect_plan(r, want, "f32", legs = legs, px = 16, file = FALSE)
  })

  test_that("a chain inside a stage writes the same cells", {
    ch <- .er_chains[[2L]]
    expect_plan(ch$x(lazy_source(.er_tile(.er_a))), ch$want(.er_a), "f32", legs = legs, px = 16)
  })

  test_that("a count reduction then a window finds NaN past the raster", {
    b <- .er_a
    b[3L, 3:5] <- NaN
    g <- graph_new()
    st <- lazy_stack(
      list(lazy_source(.er_tile(.er_a), graph = g), lazy_source(.er_tile(b), graph = g)),
      along = "t"
    )
    r <- focal_map(reduce_over(st, "count", "t"), .er_sum, 1L)
    n <- ifelse(is.nan(b), 1, 2)
    want <- .er_win(n, 1L, sum)
    expect_plan(r, want, "f64", file = FALSE, legs = list(.host, .leg(decision = "none")))
    expect_plan(r, want, "f64", px = .er_px, file = FALSE,
                legs = list(.host, .leg(decision = "none")))
  })

  test_that("a patch over a member finds NaN past the raster", {
    # left neighbour plus right, the window's own kernel
    beside <- function(v) {
      n <- length(.g_shape(v))
      ny <- .g_shape(v)[[n - 1L]]
      nx <- .g_shape(v)[[n]]
      g_pad(
        g_shift_slice(v, 0L, -1L, ny - 2L, nx - 2L, 1L) +
          g_shift_slice(v, 0L, 1L, ny - 2L, nx - 2L, 1L),
        1L,
        0
      )
    }
    x <- lazy_source(.er_tile(.er_a))
    r <- lazy_patch(lazy_map(x, fn = .er_fill), beside, radius = 1L, kernel_id = "beside")
    want <- .er_a
    want[, c(1L, .er_nx)] <- NaN
    want[, 2:(.er_nx - 1L)] <- .er_a[, 1:(.er_nx - 2L)] + .er_a[, 3:.er_nx]
    expect_plan(r, want, "f32", legs = wide, px = 16, file = FALSE, tolerance = .er_tol)
  })

  test_that("a window finds its parent's nodata, whatever it returns itself", {
    # an i32 patch over a float map: the left neighbour, -7 where that is NaN
    left <- function(v) {
      n <- length(.g_shape(v))
      s <- g_shift_slice(v, 0L, -1L, .g_shape(v)[[n - 1L]] - 2L, .g_shape(v)[[n]] - 2L, 1L)
      g_cast(g_pad(g_ifelse(g_is_nodata(s), -7, s), 1L, 0), "i32")
    }
    x <- lazy_source(.er_tile(.er_a))
    r <- lazy_patch(lazy_map(x, fn = .er_fill), left, radius = 1L, dtype = "i32",
                    kernel_id = "left")
    want <- .er_a
    want[, 1L] <- -7
    want[, 2:.er_nx] <- .er_a[, 1:(.er_nx - 1L)]
    expect_plan(r, want, "i32", legs = wide, px = 16, file = FALSE)
  })

  # -- gdal-direct routes ------------------------------------------------------

  # Two slices of a 60 x 40 GTI and their median, the composite the upper
  # kernel of a reduce-decomposed plan starts from.
  gd_comp <- function() {
    g <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
    gg <- graph_new()
    reduce_over(lazy_stack(list(.gg_slice(g, "s1", gg), .gg_slice(g, "s2", gg))), "median", "t")
  }
  sched <- function(mode) {
    .leg(opts = list(garry.composite_direct = FALSE, garry.placement = mode))
  }

  test_that("the upper kernel of a reduce agrees with the scheduler", {
    a <- .gg_val(5)
    for (nm in names(.er_chains)) {
      ch <- .er_chains[[nm]]
      expect_plan(ch$x(gd_comp()), ch$want(a), ch$dtype %||% "f32", legs = list(.leg("gd_reduce")),
                  file = FALSE, info = nm, tolerance = 2e-5)
    }
    ch <- .er_chains[[1L]]
    expect_plan(ch$x(gd_comp()), ch$want(a), "f32", legs = list(sched("rules"), .host),
                file = FALSE, tolerance = 2e-5)
  })

  # A value band and a QA band over two slices, flags on the raster's edge and
  # corner and a speck well inside it.
  edge_flags <- function(slice) {
    m <- matrix(FALSE, 40L, 60L)
    if (slice == 1L) {
      m[1:6, 10:24] <- TRUE
      m[20L, 30L] <- TRUE
    } else {
      m[30:40, 50:60] <- TRUE
      m[15:25, 1:3] <- TRUE
    }
    m
  }
  edge_composite <- function(open, dilate, type = "Float32", dtype = "f32", where = 2,
                             two = FALSE) {
    q <- function(i) ifelse(edge_flags(i), 2, 1)
    gV <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
    gQ <- .gg_gti(list(s1 = q(1L), s2 = q(2L)), type)
    g <- graph_new()
    sl <- function(gti, d) list(s1 = .gg_slice(gti, "s1", g, d), s2 = .gg_slice(gti, "s2", g, d))
    vars <- list(V = sl(gV, "f32"))
    if (two) {
      vars$W <- sl(.gg_gti(list(s1 = .gg_val(100), s2 = .gg_val(110))), "f32")
    }
    ds <- as_dataset(c(vars, list(Q = sl(gQ, dtype))), mask_asset = "Q")
    stack_bands(reduce_over(apply_mask(ds, where = where, open = open, dilate = dilate),
                            "median", "t", nan_rm = TRUE))
  }
  # Morphology on the raster's cells, by a disk of radius r, with past the
  # raster reading as clear: scipy's constant-0 border.
  morph <- function(m, r, f) {
    o <- expand.grid(dy = -r:r, dx = -r:r)
    o <- o[o$dx^2 + o$dy^2 <= r^2, ]
    p <- matrix(FALSE, nrow(m) + 2L * r, ncol(m) + 2L * r)
    p[r + seq_len(nrow(m)), r + seq_len(ncol(m))] <- m
    out <- m
    for (i in seq_len(nrow(m))) {
      for (j in seq_len(ncol(m))) {
        out[i, j] <- f(p[cbind(i + r + o$dy, j + r + o$dx)])
      }
    }
    out
  }
  clean <- function(m, open, dilate) {
    if (open > 0L) {
      m <- morph(morph(m, open, all), open, any)
    }
    if (dilate > 0L) {
      m <- morph(m, dilate, any)
    }
    m
  }
  edge_want <- function(open, dilate) {
    a <- .gg_val(0)
    b <- .gg_val(10)
    a[clean(edge_flags(1L), open, dilate)] <- NaN
    b[clean(edge_flags(2L), open, dilate)] <- NaN
    ifelse(is.nan(a), b, ifelse(is.nan(b), a, (a + b) / 2))
  }

  test_that("apply_mask keeps a mask on the raster's edge, on every route", {
    for (a in list(c(1L, 1L), c(2L, 3L))) {
      x <- edge_composite(a[[1L]], a[[2L]])
      expect_plan(x, edge_want(a[[1L]], a[[2L]]), "f32", file = FALSE, info = toString(a),
                  legs = list(.leg("composite_direct"), sched("rules"), .host))
    }
    expect_plan(x, edge_want(2L, 3L), "f32", px = 600, file = FALSE,
                legs = c(list(sched("rules"), .host), if (length(fused)) list(sched("cost"))))
    # two bands take the pipeline, whose mask runs on a compute daemon
    want <- array(c(edge_want(2L, 3L), edge_want(2L, 3L) + 100), c(40L, 60L, 2L))
    expect_plan(edge_composite(2L, 3L, two = TRUE), want, "f32", file = FALSE,
                legs = list(.leg("composite_direct")))
  })

  test_that("a mask chain the fast route replays finds NaN past the raster", {
    # a mask of its own, not morphology: a window summing a NaN-filling map
    gV <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
    gQ <- .gg_gti(list(s1 = ifelse(edge_flags(1L), 2, 1), s2 = ifelse(edge_flags(2L), 2, 1)))
    g <- graph_new()
    layer <- function(s) {
      pred <- lazy_map(.gg_slice(gQ, s, g), fn = function(f) g_cast(f == 2, "f32"), dtype = "f32")
      lazy_map(.gg_slice(gV, s, g), focal_map(pred, .er_sum, 1L), dtype = "f32",
               fn = function(v, m) g_ifelse(m > 0.5, NaN, v))
    }
    x <- reduce_over(lazy_stack(list(layer("s1"), layer("s2"))), "median", "t", nan_rm = TRUE)
    masked <- function(v, i) {
      n <- .er_win(edge_flags(i) + 0, 1L, sum)
      v[!is.nan(n) & n > 0.5] <- NaN
      v
    }
    a <- masked(.gg_val(0), 1L)
    b <- masked(.gg_val(10), 2L)
    want <- ifelse(is.nan(a), b, ifelse(is.nan(b), a, (a + b) / 2))
    expect_plan(x, want, "f32", file = FALSE,
                legs = list(.leg("composite_direct"), sched("rules"), .host))
  })

  test_that("past the raster reads clear when an integer QA's 0 flags a cell", {
    # A Byte read pads with 0 and `where` holds 0, so the predicate flags the
    # ring, which no window may read.
    x <- edge_composite(1L, 1L, type = "Byte", dtype = "u8", where = c(0, 2))
    expect_plan(x, edge_want(1L, 1L), "f32", file = FALSE,
                legs = list(.leg("composite_direct"), sched("rules"), .host))
  })

  test_that("a NaN from `where` reads clear at its own cell and goes no further", {
    # the predicate keeps a QA cell's NaN, well inside a flagged block
    flags <- matrix(FALSE, 24L, 30L)
    flags[6:14, 8:20] <- TRUE
    flags[20L, 6L] <- TRUE
    qa <- ifelse(flags, 2, 1)
    qa[10L, 14L] <- NaN
    clear <- replace(flags, cbind(10L, 14L), FALSE)
    val <- outer(1:24, 1:30, `+`) + 0
    g <- graph_new()
    ds <- as_dataset(list(V = list(s1 = lazy_source(.er_tile(val), graph = g)),
                          Q = list(s1 = lazy_source(.er_tile(qa), graph = g))),
                     mask_asset = "Q")
    for (a in list(c(1L, 1L), c(2L, 0L), c(0L, 2L))) {
      m <- apply_mask(ds, where = function(f) f - 1, open = a[[1L]], dilate = a[[2L]])
      want <- replace(val, clean(clear, a[[1L]], a[[2L]]), NaN)
      expect_plan(m@bands$V$s1, want, "f32", px = 100, file = FALSE, info = toString(a),
                  legs = c(list(.host, sched("rules")), if (length(fused)) list(sched("cost"))))
    }
  })

  test_that("morphology over a member equals morphology over a file", {
    m <- edge_flags(1L)
    want <- clean(m, 1L, 0L) + 0
    q <- lazy_source(.er_tile(ifelse(m, 2, 1)))
    pred <- lazy_map(q, fn = function(v) g_cast(v == 2, "f32"), dtype = "f32")
    inside <- .dilate(.erode(pred, 1L), 1L)
    expect_plan(inside, want, "f32", px = 600, file = FALSE, legs = c(list(.host), fused))
    across <- .dilate(.erode(lazy_source(.er_tile(m + 0)), 1L), 1L)
    expect_plan(across, want, "f32", px = 600, file = FALSE, legs = c(list(.host), fused))
  })
})
