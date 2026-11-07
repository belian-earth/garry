# End-to-end gate for cost-mode fusion of a WIDE kernel (the PR5
# pathway of design/placement-cost-pass.md): with capped readers and
# placement = "cost", a coalesced multi-band MLP chain executes fused
# on the read tasks, with no chunk tasks of its own, and the result is
# the MLP's forward pass in plain R. This is the correctness half of
# PR5; the wall-time half is the SI predict benchmark.

# The fixture's bands as one stack.
.fw_stack <- function(fx, bands = seq_len(fx$nb), g = graph_new()) {
  lazy_stack(lapply(bands, function(b) lazy_source(fx$path, band = b, graph = g)), along = "band")
}

# One hidden layer `width` wide over `nb` bands. Fixed weights, so that a
# failure replays.
.fw_mlp <- function(width, nb) {
  list(
    weights = list(matrix(seq_len(width * nb) / 100, width), matrix(seq_len(width) / 10, 1L)),
    biases = list(rep(0, width), 0)
  )
}

.fw_predict <- function(st, m, ...) {
  reduce_over(st, mlp_project(m$weights, m$biases, ...), over = "band")
}

# That forward pass in plain R, [y, x]: ReLU on the hidden layer.
.fw_want <- function(fx, m, bands = seq_len(fx$nb)) {
  h <- t(vapply(fx$vals[bands], as.numeric, numeric(fx$nx * fx$ny)))
  h <- pmax(m$weights[[1L]] %*% h + m$biases[[1L]], 0)
  matrix(m$weights[[2L]] %*% h + m$biases[[2L]], fx$ny, fx$nx)
}

# A trailing spatial reduce keeps the predict chain in its own NON-SINK
# single-input compute stage (spatial reduces split into partial/combine
# stages); chunk-local consumers merge into the predict stage and ride the
# fusion with it.
.fw_chain <- function(fx, m) {
  plan_lazy(reduce_over(.fw_predict(.fw_stack(fx), m) * 2, "mean", c("x", "y"), nan_rm = TRUE))
}

# Cost mode in the caller's frame. RAM is fixed at plenty, so that what a test
# asserts is the pass and not the host's free memory.
.fw_cost <- function(..., env = parent.frame()) {
  withr::local_options(garry.placement = "cost", ..., .local_envir = env)
  testthat::local_mocked_bindings(.garry_ram_avail_mb = function() 1e6, .package = "garry", .env = env)
}

# -- tiled fused kernels ------------------------------------------------------

test_that(".apply_fuse_tiled equals one whole-window call", {
  skip_if(!requireNamespace("anvl", quietly = TRUE), "anvl not installed")
  set.seed(5)
  nb <- 6L; ny <- 23L; nx <- 9L
  w1 <- matrix(runif(8L * nb), 8L); w2 <- matrix(runif(8L), 1L)
  body <- mlp_project(list(w1, w2), list(rep(0, 8L), 0))
  fn <- function(inputs) list(body(inputs[[1L]], 1L))
  jf <- g_jit(fn)
  cube <- array(rnorm(nb * ny * nx), c(nb, ny, nx))
  cube[2, 4, 5] <- NaN
  up <- g_upload(cube, "f32")
  whole <- g_download(jf(list(up))[[1L]])
  for (k in c(2L, 4L, 7L, 23L, 50L)) {          # uneven splits; > ny clamps
    tiled <- g_download(garry:::.apply_fuse_tiled(jf, up, k))
    expect_identical(dim(tiled), dim(whole), label = paste("tiles", k))
    expect_identical(is.na(tiled), is.na(whole))
    expect_equal(tiled, whole, tolerance = 1e-6, label = paste("tiles", k))
  }
  # a 3-D export (band-preserving map) concatenates along y too
  fn3 <- function(inputs) list(inputs[[1L]] * 2 + 1)
  jf3 <- g_jit(fn3)
  whole3 <- g_download(jf3(list(up))[[1L]])
  tiled3 <- g_download(garry:::.apply_fuse_tiled(jf3, up, 5L))
  expect_equal(tiled3, whole3, tolerance = 1e-6)
})

test_that("tiling lets a window over .fuse_reader_mb fuse instead of materialising", {
  fx <- fixture_multiband()
  p <- .fw_chain(fx, .fw_mlp(8L, fx$nb))
  # reader budget below the whole-window working set but above the
  # input window: untiled it must materialise, tiled it fuses
  .fw_cost(garry.chunk_target_px = 400)
  tab0 <- garry_explain_placement(p, read = 4L, compute = 1L)
  cid <- tab0[tab0$bands > 1L, ]$compute
  C <- p@stages[[cid]]; S <- p@stages[[C@inputs[[1L]]]]
  win_px <- prod(pmin(as.numeric(S@chunks@chunk_dim),
                      as.numeric(S@grid@dims[c("x", "y")])))
  win_rows <- min(S@chunks@chunk_dim[[2L]], S@grid@dims[["y"]])
  withr::local_options(garry.ram_budget_mb = 1e9)
  whole <- garry:::.fuse_tiles(p@graph, C, win_px, win_rows, fx$nb)
  withr::local_options(garry.ram_budget_mb = whole$act_mb / 8)
  tiled <- garry:::.fuse_tiles(p@graph, C, win_px, win_rows, fx$nb)
  expect_gte(tiled$tiles, 8L)
  expect_lt(tiled$ws_mb, whole$ws_mb)
  # a reader budget between the tiled and the whole working set
  testthat::local_mocked_bindings(.fuse_reader_mb = (tiled$ws_mb + whole$ws_mb) / 2)
  withr::local_options(garry.ram_budget_mb = 1e9)
  t_un <- garry_explain_placement(p, read = 4L, compute = 1L)
  expect_identical(t_un[t_un$bands > 1L, ]$decision, "comp")
  withr::local_options(garry.ram_budget_mb = whole$act_mb / 8)
  t_ti <- garry_explain_placement(p, read = 4L, compute = 1L)
  expect_identical(t_ti[t_ti$bands > 1L, ]$decision, "fuse")
})

test_that(".fuse_tiles keeps a halo chain whole and prices input plus activations", {
  fx <- fixture_multiband()
  p <- .fw_chain(fx, .fw_mlp(8L, fx$nb))
  .fw_cost(garry.chunk_target_px = 400, garry.ram_budget_mb = 1e-4)
  tab <- garry_explain_placement(p, read = 4L, compute = 1L)
  C <- p@stages[[tab[tab$bands > 1L, ]$compute]]
  win_px <- 60 * 40
  tl <- garry:::.fuse_tiles(p@graph, C, win_px, 40L, fx$nb)
  expect_gt(tl$tiles, 1L)
  # a halo (or out_pad) chain is not tileable: whole window, full activations
  Ch <- C; Ch@halo <- 1L
  th <- garry:::.fuse_tiles(p@graph, Ch, win_px, 40L, fx$nb)
  expect_identical(th$tiles, 1L)
  expect_equal(th$ws_mb, th$in_mb + th$act_mb)
  Cp <- C; Cp@out_pad <- 1L
  expect_identical(garry:::.fuse_tiles(p@graph, Cp, win_px, 40L, fx$nb)$tiles, 1L)
  # The input term is 8 bytes of host buffer + 4 of device copy on each of
  # 6 bands. Activations leave the copy out: 4 bytes on the hidden layer's
  # 8 planes and on the 8 its matmul holds.
  expect_equal(tl$in_mb, 2400 * 72 / 2^20)
  expect_equal(tl$act_mb, 2400 * 64 / 2^20)
})

# -- seal at a fanned-out reduce ----------------------------------------------

.fw_fan <- function(fx) .fw_predict(.fw_stack(fx), .fw_mlp(8L, fx$nb))

test_that("a fanned-out band reduce fed by a source keeps its own single-export stage", {
  fx <- fixture_multiband()
  withr::local_options(garry.placement = "cost")
  own_stage <- function(p, pred) {
    Filter(function(s) s@kind == "compute" && pred@node_id %in% s@members, p@stages)
  }
  pred <- .fw_fan(fx)
  x <- list(a = pred * 2, b = pred + 1,
            c = lazy_map(pred, fn = function(v) sqrt(abs(v)), dtype = "f32"))
  p <- plan_lazy(x)
  own <- own_stage(p, pred)
  expect_length(own, 1L)
  expect_identical(own[[1L]]@exports, pred@node_id)     # single export
  expect_identical(own[[1L]]@members, pred@node_id)     # consumers cut off
  down <- Filter(function(s) s@kind == "compute" && own[[1L]]@id %in% s@inputs,
                 p@stages)
  expect_length(down, 1L)                               # one downstream stage
  expect_identical(sort(down[[1L]]@exports), sort(unname(p@sinks)))
  # a plan worth merging keeps the seal: small chunks clear .merge_worth()
  withr::with_options(list(garry.chunk_target_px = 4L), {
    expect_identical(own_stage(plan_lazy(x), pred)[[1L]]@members, pred@node_id)
  })

  # ONE consumer: no seal, the map fuses into the reduce's stage as before
  pred1 <- .fw_fan(fx)
  expect_gt(length(own_stage(plan_lazy(pred1 * 2), pred1)[[1L]]@members), 1L)

  # rules placement: no seal
  withr::local_options(garry.placement = "rules")
  pred2 <- .fw_fan(fx)
  p2 <- plan_lazy(list(a = pred2 * 2, b = pred2 + 1))
  expect_gt(length(own_stage(p2, pred2)[[1L]]@members), 1L)
})

# A skip here ends the file, so this block stays last.
local({
  skip_if(Sys.info()[["sysname"]] != "Linux", "affinity is Linux-only")
  skip_if(!nzchar(Sys.which("taskset")), "taskset not available")
  skip_if(garry:::.garry_cores()$logical < 3L, "a reader cap is a no-op below 3 CPUs")

  local_pools(4, 1, gdal_config = TRUE)

  test_that("cost mode fuses a multi-band MLP chain onto capped readers, tiled or not", {
    fx <- fixture_multiband()
    m <- .fw_mlp(8L, fx$nb)
    p <- .fw_chain(fx, m)
    want <- mean(.fw_want(fx, m) * 2)
    tlog <- withr::local_tempfile(fileext = ".csv")
    .fw_cost(garry.chunk_target_px = 400, garry.task_log = tlog)

    # the pass must have decided FUSE for the MLP chain under this
    # topology (capped readers recorded by garry_daemons), at one tile
    # for so small a window
    tab <- garry_explain_placement(p)
    mlp <- tab[tab$bands > 1L, ]
    expect_identical(mlp$decision, "fuse")
    expect_identical(mlp$tiles, 1L)
    expect_equal(execute_plan_mirai(p), want, tolerance = 1e-5)

    # fused: the MLP stage ran on its read tasks, no chunk tasks of its own
    keys <- read.csv(tlog)$key
    expect_true(any(startsWith(keys, sprintf("s%d_", mlp$source))))
    expect_false(any(startsWith(keys, sprintf("s%d_", mlp$compute))))

    # a tiny per-call activation budget forces several row tiles
    # (the plan is built, so this only reaches the per-call budget)
    withr::local_options(garry.ram_budget_mb = 1e-4)
    tab <- garry_explain_placement(p)
    mlp <- tab[tab$bands > 1L, ]
    expect_identical(mlp$decision, "fuse")
    expect_gt(mlp$tiles, 1L)
    expect_equal(execute_plan_mirai(p), want, tolerance = 1e-5)
  })

  test_that("a SINK-shaped MLP predict fuses and streams (the SI shape)", {
    # The SI predict collect: per-embedding predictions are multi-export
    # SINKS. Under cost mode they fuse onto the readers and the streaming
    # writers pull each sink chunk out of its source's read task.
    fx <- fixture_multiband()
    g <- graph_new()
    mlps <- list(p8 = .fw_mlp(8L, fx$nb), p16 = .fw_mlp(16L, fx$nb))
    sinks <- lapply(mlps, function(m) .fw_predict(.fw_stack(fx, g = g), m))
    p <- plan_lazy(sinks)
    want <- lapply(mlps, function(m) .fw_want(fx, m))

    .fw_cost(garry.chunk_target_px = 400)
    tab <- garry_explain_placement(p)
    expect_true(all(tab$decision == "fuse"))

    # in-memory retrieval from the fused read tasks
    dist <- execute_plan_mirai(p)
    expect_equal(dist$p8, want$p8, tolerance = 1e-5)
    expect_equal(dist$p16, want$p16, tolerance = 1e-5)

    # streamed writes from the fused read tasks
    d <- withr::local_tempdir()
    execute_plan_mirai(p, path = d)
    for (nm in names(sinks)) {
      got <- gdal_read_window(file.path(d, paste0(nm, ".tif")), 1L, 0, 0, fx$nx, fx$ny)
      expect_equal(got, want[[nm]], tolerance = 1e-5, label = nm)
    }
  })

  test_that("a QA-gated predict (QA as last plane) fuses and matches (the ESD shape)", {
    # hutan predict_mlp_lazy's new shape: features + QA in ONE cube, the
    # gate inside mlp_project: single-input, so the big arm can fuse.
    fx <- fixture_multiband()
    feats <- seq_len(fx$nb - 1L)
    m <- .fw_mlp(8L, length(feats))
    pred <- .fw_predict(.fw_stack(fx), m, qa_plane = fx$nb, qa_floor = 500)
    p <- plan_lazy(list(pred = pred))
    want <- .fw_want(fx, m, feats)
    gated <- fx$vals[[fx$nb]] < 500
    want[gated] <- NaN
    expect_true(any(gated))       # the floor gates something
    expect_false(all(gated))

    .fw_cost(garry.chunk_target_px = 400)
    tab <- garry_explain_placement(p)
    expect_identical(tab$decision, "fuse")
    expect_identical(tab$bands, as.integer(fx$nb))

    expect_equal(execute_plan_mirai(p), want, tolerance = 1e-5)
  })

  test_that("a fanned-out band reduce fuses on a capped pool and matches", {
    fx <- fixture_multiband()
    .fw_cost()
    pred <- .fw_fan(fx)
    x <- list(a = pred * 2, b = pred + 1,
              c = lazy_map(pred, fn = function(v) sqrt(abs(v)), dtype = "f32"))
    p <- plan_lazy(x)
    own <- Filter(function(s) s@kind == "compute" && pred@node_id %in% s@members, p@stages)
    tab <- garry_explain_placement(p)
    expect_identical(tab$compute, own[[1L]]@id)
    expect_identical(tab$decision, "fuse")
    v <- .fw_want(fx, .fw_mlp(8L, fx$nb))
    want <- list(a = v * 2, b = v + 1, c = sqrt(abs(v)))
    dist <- execute_plan_mirai(p)
    for (nm in names(x)) expect_equal(dist[[nm]], want[[nm]], tolerance = 1e-5)
  })
})
