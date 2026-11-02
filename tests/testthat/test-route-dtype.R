# The dtype a plan declares is the dtype it runs at, on every route. Each
# row takes one dtype through one kernel shape on a tiny raster and holds
# the result, in memory and in a file, to a value worked out in plain R.

# Cells from both ends of each band's range, with room for the + 1.
.rd_types <- list(
  u8 = list(type = "Byte", vals = c(0, 254, 7, 100)),
  i8 = list(type = "Int8", vals = c(-128, 126, 7, -100)),
  u16 = list(type = "UInt16", vals = c(0, 65534, 7, 1000)),
  i16 = list(type = "Int16", vals = c(-32768, 32766, 7, -1000)),
  u32 = list(type = "UInt32", vals = c(0, 4294967294, 7, 1000)),
  i32 = list(type = "Int32", vals = c(-2147483647, 2147483646, 7, -1000)),
  f32 = list(type = "Float32", vals = c(-1.5, 2.25, 7, 1000)),
  # no f32 holds these, and they add up exactly in any order
  f64 = list(type = "Float64", vals = c(-1 - 2^-30, 2 + 2^-30, 7, 1000))
)

# The source's cells [y, x], in plain R.
.rd_m <- function(vals) matrix(rep_len(as.numeric(vals), 24L), 4L, 6L, byrow = TRUE)
.rd_src <- function(dt) {
  lazy_source(fixture_tile(.rd_types[[dt]]$vals, .rd_types[[dt]]$type, nx = 6L))
}

# The float dtype arithmetic on `dt` runs at, and a value held at it.
.rd_float <- function(dt) if (dt == "f64") "f64" else "f32"
.rd_at <- function(v, float) if (float == "f64") v else .as_f32(v)

# One closure per kernel, whatever the dtype: a program built for one dtype
# and handed to another shows as a wrong value.
.rd_add <- function(v) v + 1L
.rd_half <- function(v) v / 2
.rd_third <- function(v) v / 3
.rd_above_1 <- function(v) v > 1L
.rd_pick <- function(m) g_ifelse(m, 2, 3)
.rd_nw <- function(sh) sh[[1L]]

# A row builds its plan on a source and says what plain R makes of the
# source's cells: list(plan, want, dtype).
.rd_rows <- list(
  # the source's own integers, past every kernel seam
  add = function(x, m, dt) {
    list(lazy_map(x, fn = .rd_add), if (dt == "f32") .as_f32(m + 1) else m + 1, .carried(dt))
  },
  # float arithmetic leaves the integer dtype and declares so
  half = function(x, m, dt) {
    fl <- .rd_float(dt)
    list(lazy_map(x, fn = .rd_half), .rd_at(.rd_at(m, fl) / 2, fl), fl)
  },
  # a named dtype holds inside a stage as it does across one
  named = function(x, m, dt) {
    fl <- .rd_float(dt)
    named <- if (startsWith(dt, "f")) "i16" else dt
    list(
      lazy_map(x, fn = .rd_third, dtype = named) * 2L,
      trunc(.rd_at(.rd_at(m, fl) / 3, fl)) * 2,
      .carried(named)
    )
  },
  # a logical stores 0/1 at its carrier and selects in the next map
  select = function(x, m, dt) {
    list(
      lazy_map(lazy_map(x, fn = .rd_above_1), fn = .rd_pick),
      ifelse(m > 1, 2, 3),
      "f32"
    )
  },
  # a predicate collects as logical, and refuses a file
  pred = function(x, m, dt) {
    list(lazy_map(x, fn = .rd_above_1, dtype = "pred"), m > 1, "pred")
  },
  # a window over a map that names its float dtype: the map keeps its
  # integer read, and the window finds NaN past the raster over either read
  focal = function(x, m, dt) {
    float <- startsWith(dt, "f")
    fn <- if (float) function(v) g_cast(v, "f32") else function(v) g_cast(g_bitand(v, 1L), "f32")
    cells <- if (float) .as_f32(m) else m %% 2
    want <- matrix(NaN, 4L, 6L)
    want[2:4, 2:6] <- cells[1:3, 1:5]
    list(focal_map(lazy_map(x, fn = fn, dtype = "f32"), .rd_nw, 1L), want, "f32")
  }
)

test_that("every dtype runs every kernel at its dtype, chunked or not", {
  for (dt in names(.rd_types)) {
    x <- .rd_src(dt)
    m <- .rd_m(.rd_types[[dt]]$vals)
    for (nm in names(.rd_rows)) {
      row <- .rd_rows[[nm]](x, m, dt)
      for (px in c(1e6, 4)) {
        expect_plan(row[[1L]], row[[2L]], row[[3L]], px = px,
                    file = px == 4 && nm %in% c("add", "half", "named", "pred"),
                    info = paste(dt, nm, px))
      }
    }
  }
})

test_that("an integer plan quantizes like a float one, chunked or not", {
  x <- lazy_source(fixture_tile(100, "Int16", nx = 6L)) + 1L
  for (px in c(1e6, 4)) {
    expect_written(x, matrix(202, 4L, 6L), "i16", scale = 0.5, px = px)
  }
})

# The f32 shapes every plan is built from, on 8 x 8 whole numbers so that
# plain R adds them up as f32 does.
.rd_shape_m <- matrix(as.numeric(1:64), 8L, 8L, byrow = TRUE)

# Sum of each cell's (2r + 1)^2 window, NaN where it leaves the raster.
.rd_box <- function(m, r) {
  pad <- matrix(NaN, nrow(m) + 2L * r, ncol(m) + 2L * r)
  pad[r + seq_len(nrow(m)), r + seq_len(ncol(m))] <- m
  out <- m * 0
  for (dy in 0:(2L * r)) for (dx in 0:(2L * r)) {
    out <- out + pad[dy + seq_len(nrow(m)), dx + seq_len(ncol(m))]
  }
  out
}

.rd_s9 <- function(sh) Reduce(`+`, sh)

.rd_shapes <- function() {
  f <- fixture_tile(1:64, "Float32", nx = 8L, ny = 8L)
  m <- .rd_shape_m
  a <- lazy_source(f)
  b <- lazy_source(f)
  list(
    ratio = list((a - b / 2) / (a + b / 2), .as_f32(m / 2 / (m * 1.5))),
    focal = list(
      focal_map(a + 1, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L),
      .as_f32(.rd_box(m + 1, 1L) / 9)
    ),
    stacked = list(focal_map(focal_map(a, .rd_s9, 1L), .rd_s9, 2L), .rd_box(.rd_box(m, 1L), 2L)),
    median = list(
      reduce_over(lazy_stack(list(a + 1, b * 2)), "median", "t", nan_rm = TRUE),
      (m + 1 + m * 2) / 2
    ),
    bands = list(
      lazy_stack(list(a * 2, b + 10), along = "band"),
      array(c(m * 2, m + 10), c(8L, 8L, 2L))
    )
  )
}

# A sentinel read as NaN, on the f32 store.
.rd_nodata_m <- .rd_m(c(-9999, 5, 7, 11))
.rd_nodata <- function() {
  lazy_source(fixture_tile(c(-9999, 5, 7, 11), "Int16", nodata = -9999, nx = 6L))
}

# Plans whose value crosses a stage boundary or two, where the dtype one
# side declares is what the other receives: list(plan, want, dtype).
.rd_stages <- function() {
  x <- lazy_source(fixture_tile(3, "Int16", nx = 6L))
  count <- lazy_map(
    reduce_over(lazy_stack(list(x, x), along = "t"), "count", "t"),
    fn = .rd_add
  )
  tw <- c(1, 2)
  tm <- .rd_m(tw)
  pm <- lazy_map(
    lazy_source(fixture_tile(tw, "Int16", nx = 6L)),
    fn = .rd_above_1,
    dtype = "pred"
  )
  um <- .rd_m(c(1000, 65535, 7, 2))
  y <- lazy_map(lazy_source(fixture_tile(c(1000, 65535, 7, 2), "UInt16", nx = 6L)),
                fn = function(v) v * 1e-4)
  yw <- .as_f32(um * .as_f32(1e-4))
  dvals <- c(1.1, 2.3, 1e10, 1 / 7)
  dm <- .rd_m(dvals)
  d <- lazy_map(lazy_source(fixture_tile(dvals, "Float64", nx = 6L)), dtype = "f64",
                fn = function(v) v * (1 / 3))
  wm <- .as_f32(dm)
  w <- lazy_map(lazy_source(fixture_tile(dvals, "Float32", nx = 6L)), dtype = "f64",
                fn = function(v) g_cast(v, "f64") * (1 / 3))
  list(
    # a count is the integer it declares
    count = list(
      list(a = count + 1L, b = count + 2L),
      list(a = matrix(4, 4L, 6L), b = matrix(5, 4L, 6L)),
      c(a = "i32", b = "i32")
    ),
    # a predicate dtype keys its programs
    pred = list(
      list(a = lazy_map(pm, fn = function(v) g_ifelse(v, 5, 0)),
           b = lazy_map(pm, fn = function(v) g_ifelse(v, 7, 0))),
      list(a = ifelse(tm > 1, 5, 0), b = ifelse(tm > 1, 7, 0)),
      c(a = "f32", b = "f32")
    ),
    # a float map over integers feeds the stages after it
    float = list(
      list(a = lazy_map(y, fn = function(v) v + 1, dtype = "f32"),
           b = lazy_map(y, fn = function(v) v * 2, dtype = "f32")),
      list(a = .as_f32(yw + 1), b = .as_f32(yw * 2)),
      c(a = "f32", b = "f32")
    ),
    # f64 survives the store bit for bit, in memory and on disk
    f64 = list(
      list(y = d,
           z = reduce_over(lazy_stack(list(d, d * 2), along = "t"), "mean", "t", nan_rm = TRUE)),
      list(y = dm * (1 / 3), z = (dm * (1 / 3) + dm * (1 / 3) * 2) / 2),
      c(y = "f64", z = "f64")
    ),
    # an f32 read widens to f64 in its kernel, so the store takes the export's
    # dtype and not the input's
    widen = list(
      list(y = w,
           z = reduce_over(lazy_stack(list(w, w * 2), along = "t"), "mean", "t", nan_rm = TRUE)),
      list(y = wm * (1 / 3), z = (wm * (1 / 3) + wm * (1 / 3) * 2) / 2),
      c(y = "f64", z = "f64")
    )
  )
}

# The rows of .rd_stages() a file holds.
.rd_on_disk <- c("f64", "widen")

# Masking gives each band a dtype NaN can live in.
.rd_masked <- function() {
  q <- .rd_m(c(0, 1))
  ds <- as_dataset(
    list(v = lazy_source(fixture_tile(3, "Int16", nx = 6L)),
         w = lazy_source(fixture_tile(1.1, "Float64", nx = 6L)),
         q = lazy_source(fixture_tile(c(0, 1), "Byte", nx = 6L))),
    mask_asset = "q"
  )
  mk <- apply_mask(ds, where = 1, from = "q")
  list(
    v = list(mk$v, ifelse(q == 1, NaN, 3), "f32"),
    w = list(mk$w, ifelse(q == 1, NaN, 1.1), "f64")
  )
}

test_that("a value crossing stages keeps its dtype, in process", {
  rows <- c(.rd_stages(), .rd_masked())
  for (nm in names(rows)) {
    row <- rows[[nm]]
    expect_plan(row[[1L]], row[[2L]], row[[3L]], px = 4, file = nm %in% .rd_on_disk, info = nm)
  }
})

local({
  local_pools(2, 1, gdal_config = TRUE)

  # Integers carry every kernel, floats the two that keep or change their
  # dtype, and each dtype reaches a file once. The shapes write f32.
  kernels <- c("add", "half", "named", "pred")
  pooled <- list(
    u16 = c(kernels, "focal"), i16 = kernels, i32 = "add", u32 = kernels,
    f32 = c("add", "half"), f64 = c("add", "half")
  )
  sweep <- function(leg) {
    for (dt in names(pooled)) {
      x <- .rd_src(dt)
      m <- .rd_m(.rd_types[[dt]]$vals)
      for (nm in pooled[[dt]]) {
        row <- .rd_rows[[nm]](x, m, dt)
        expect_plan(row[[1L]], row[[2L]], row[[3L]], legs = list(leg), px = 4,
                    file = (nm == "add" && dt != "f32") || (nm == "half" && dt == "i16"),
                    info = paste(dt, nm))
      }
    }
  }

  shapes <- function(leg) {
    rows <- .rd_shapes()
    for (nm in names(rows)) {
      row <- rows[[nm]]
      expect_plan(row[[1L]], row[[2L]], "f32", legs = list(leg), px = 9,
                  file = nm == "bands", info = nm)
    }
    # a sentinel reaches the kernel as NaN
    expect_plan(.rd_nodata() + 0.5, ifelse(.rd_nodata_m == -9999, NaN, .rd_nodata_m + 0.5),
                "f32", legs = list(leg), px = 4, file = FALSE)
  }

  # A band stack of arithmetic on a sentinel source, stored as i8: rounded,
  # saturated at the band's limit, NaN on the sentinel a read marks again.
  int8_bands <- function(leg) {
    a <- c(-9999, 1234, -5000, 30000)
    m <- .rd_m(a)
    m[m == -9999] <- NaN
    x <- lazy_source(fixture_tile(a, "Int16", nodata = -9999, nx = 6L))
    want <- array(c(pmin(round(m / 100), 127), m * 0 + 7), c(4L, 6L, 2L))
    expect_written(lazy_stack(list(x / 100, x * 0 + 7), along = "band"), want, "i8",
                   legs = list(leg), nodata = -128, px = 4)
  }

  # A kernel under a spatial reduce hands on the dtype it declares. `map`
  # builds the kernel on its source.
  under_reduce <- function(leg, map) {
    legs <- list(leg)
    x <- lazy_source(fixture_tile(3, "Int16", nx = 6L))
    expect_plan(reduce_over(map(x, .rd_half), "mean", c("x", "y")), 1.5, "f32", legs = legs, px = 4)
    # the sum of the cells over their count, as the host combines them
    v <- .rd_nodata_m[.rd_nodata_m != -9999]
    twice <- function(a) a * 2
    expect_plan(reduce_over(map(.rd_nodata(), twice), "mean", c("x", "y"), nan_rm = TRUE),
                sum(v * 2) / length(v), "f32", legs = legs, px = 4)
    # the cast a named dtype makes is what the next stage reads: 1, not 1.5
    named <- map(x, .rd_half, dtype = "i16")
    expect_plan(
      list(a = reduce_over(named, "mean", c("x", "y")), b = reduce_over(named, "max", c("x", "y"))),
      list(a = 1, b = 1),
      c(a = "f32", b = "i16"),
      legs = legs,
      px = 4
    )
  }

  # A kernel on one read fuses under either placement. A second source gives
  # it two inputs, which no read can feed, so it stays on the compute pool.
  on_one_read <- function(x, fn, ...) lazy_map(x, fn = fn, ...)
  on_two_reads <- function(x, fn, ...) {
    zero <- lazy_source(fixture_tile(0, "Int16", nx = 6L))
    lazy_map(x, zero, fn = function(a, b) fn(a + b), ...)
  }

  # A sink is quantized where it is computed.
  quantized <- function(leg) {
    x <- lazy_source(fixture_tile(100, "Int16", nx = 6L))
    expect_written(x + 1L, matrix(202, 4L, 6L), "i16", legs = list(leg), scale = 0.5, px = 4)
  }

  test_that("the compute pool runs a kernel at its dtype", {
    sweep(.comp)
  })

  test_that("a kernel fused on its reads runs at its dtype", {
    skip_on_os("mac") # the fused path hangs there: test-compute-on-read.R
    sweep(.fused)
  })

  test_that("plan shapes hold on the compute pool", {
    shapes(.comp)
  })

  test_that("plan shapes hold fused on their reads", {
    skip_on_os("mac")
    shapes(.fused)
  })

  test_that("a spatial reduce adds up the cells of every chunk", {
    for (dt in c("u16", "i32", "f32")) {
      m <- .rd_m(.rd_types[[dt]]$vals)
      expect_plan(reduce_over(.rd_src(dt), "sum", c("x", "y")), sum(m),
                  if (dt == "f32") "f32" else "i64",
                  legs = list(.leg(decision = "none")), px = 4, info = dt)
    }
  })

  test_that("a sum over a stack is exact at the integer dtype it declares", {
    # past 2^24 an f32 accumulator rounds odd additions away
    vals <- withr::with_seed(1L, lapply(1:260, function(i) matrix(sample(60000:65535, 2400L, TRUE), 40L, 60L)))
    names(vals) <- sprintf("s%03d", seq_along(vals))
    gti <- .gg_gti(vals, "UInt16")
    g <- graph_new()
    x <- reduce_over(lazy_stack(lapply(names(vals), function(s) .gg_slice(gti, s, g, "u16"))), "sum", "t")
    expect_null(.cd_reduce_spec(function(id) graph_get(x@graph, id), graph_get(x@graph, x@node_id)))
    expect_plan(x, Reduce(`+`, vals), "i32", legs = list(.leg(decision = "none")), file = FALSE)
    # a float sum runs at its dtype on the direct route, which keeps it
    f <- .gg_gti(list(s1 = matrix(1.5, 40L, 60L), s2 = matrix(2.25, 40L, 60L)))
    y <- reduce_over(lazy_stack(lapply(c("s1", "s2"), function(s) .gg_slice(f, s, g))), "sum", "t")
    expect_plan(y, matrix(3.75, 40L, 60L), "f32", legs = list(.leg("composite_direct")), file = FALSE)
  })

  test_that("a kernel under a reduce hands on its dtype on the compute pool", {
    under_reduce(.leg(decision = "none"), on_two_reads)
  })

  test_that("a kernel under a reduce fuses, and hands on its dtype", {
    skip_on_os("mac")
    under_reduce(.fused, on_one_read)
  })

  test_that("a value crossing stages keeps its dtype across daemons", {
    rows <- c(.rd_stages(), .rd_masked())
    # none of these has a chain to place, so either mode runs the same tasks
    for (nm in names(rows)) {
      row <- rows[[nm]]
      expect_plan(row[[1L]], row[[2L]], row[[3L]], legs = list(.leg(decision = "none")),
                  px = 4, file = nm %in% .rd_on_disk, info = nm)
    }
  })

  test_that("a narrow integer write rounds, saturates and marks NaN", {
    int8_bands(.comp)
  })

  test_that("a narrow integer write fused on its reads does the same", {
    skip_on_os("mac")
    int8_bands(.fused)
  })

  test_that("an integer plan quantizes on every distributed route", {
    quantized(.comp)
    tail <- 0L
    real <- garry:::.exec_quantize_value
    testthat::local_mocked_bindings(
      .exec_quantize_value = function(v, wq) {
        tail <<- tail + !is.null(wq)
        real(v, wq)
      },
      .package = "garry"
    )
    # three sinks of one stage, which no other stage reads: its daemon
    # quantizes each of them, so none reaches the host tail
    x <- lazy_source(fixture_tile(100, "Int16", nx = 6L))
    y <- x + 1L
    expect_written(
      list(a = y, b = y + 2L, c = y + 3L),
      list(a = matrix(202, 4L, 6L), b = matrix(206, 4L, 6L), c = matrix(208, 4L, 6L)),
      "i16", legs = list(.leg(decision = "none")), scale = 0.5, px = 4
    )
    expect_identical(tail, 0L)
    # a read has no producer to quantize it, so the host tail does
    expect_written(list(a = x, b = x + 1L), list(a = matrix(200, 4L, 6L), b = matrix(202, 4L, 6L)),
                   "i16", legs = list(.leg(decision = "none")), scale = 0.5, px = 4)
    expect_gt(tail, 0L)
  })

  test_that("a fused integer plan quantizes", {
    skip_on_os("mac")
    quantized(.fused)
  })

  test_that("warm-up fills the compute pool's kernel cache", {
    # the pool's cache outlives a run, so this test starts it empty, and a
    # kernel no other test here compiles is one the host sends cold
    garry:::.pool_broadcast(quote(asNamespace("garry")$.exec_jit_clear()))
    tlog <- withr::local_tempfile(fileext = ".csv")
    withr::local_options(garry.task_log = tlog, garry.placement = "rules")
    x <- lazy_map(lazy_source(fixture_tile(1, "Float32", nx = 6L)), fn = function(v) v + 2.5)
    .expect_cells(unclass(collect(x, distributed = TRUE)), matrix(3.5, 4L, 6L))
    expect_true(any(startsWith(utils::read.csv(tlog)$key, "warm")))
    n <- vapply(
      garry:::.comp_profiles(),
      function(p) mirai::mirai(length(ls(garry:::.daemon_cache)), .compute = p)[],
      integer(1)
    )
    expect_gt(sum(n), 0L)
  })
})
