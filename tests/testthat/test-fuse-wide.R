# End-to-end gate for cost-mode fusion of a WIDE kernel (the PR5
# pathway of design/placement-cost-pass.md): with capped readers and
# placement = "cost", a coalesced multi-band MLP chain executes fused
# on the read tasks — no chunk tasks of its own — and the result is
# identical to the single-threaded oracle (which never fuses). This is
# the correctness half of PR5; the wall-time half is the SI predict
# benchmark.

skip_if(Sys.info()[["sysname"]] != "Linux", "affinity is Linux-only")
skip_if(!nzchar(Sys.which("taskset")), "taskset not available")
skip_if(parallel::detectCores() < 5L, "reader cap is a no-op below 5 cores")

test_that("cost mode fuses a multi-band MLP chain onto capped readers", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  fx <- fixture_multiband()
  g <- graph_new()
  bands <- lapply(seq_len(fx$nb), function(b)
    lazy_source(fx$path, band = b, graph = g))
  st <- lazy_stack(bands, along = "band")
  w1 <- matrix(runif(8L * fx$nb), 8L)
  w2 <- matrix(runif(8L), 1L)
  pred <- reduce_over(st, mlp_project(list(w1, w2),
                                      list(rep(0, 8L), 0)),
                      over = "band")
  # a trailing spatial reduce keeps the predict chain in its own
  # NON-SINK single-input compute stage (spatial reduces split into
  # partial/combine stages); chunk-local consumers merge into the
  # predict stage and ride the fusion with it
  p <- plan_lazy(reduce_over(pred * 2, "mean", c("x", "y"),
                             nan_rm = TRUE))

  single <- execute_plan(p)

  local_pools(4, 1, gdal_config = TRUE)
  tlog <- tempfile(fileext = ".csv")
  old <- options(garry.placement = "cost", garry.chunk_target_px = 400,
                 garry.task_log = tlog)
  on.exit(options(old), add = TRUE)

  # the pass must have decided FUSE for the MLP chain under this
  # topology (capped readers recorded by garry_daemons)
  tab <- garry_explain_placement(p)
  mlp <- tab[tab$bands > 1L, ]
  expect_identical(mlp$decision, "fuse")

  dist <- execute_plan_mirai(p)
  expect_equal(dist, single, tolerance = 1e-12)

  # fused: the MLP stage ran on its read tasks, no chunk tasks of its own
  tl <- read.csv(tlog)
  expect_false(any(grepl(sprintf("^s%d_c", mlp$compute), tl$key)))
})

test_that("a SINK-shaped MLP predict fuses and streams (the SI shape)", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  # The SI predict collect: per-embedding predictions are multi-export
  # SINKS. Under cost mode they fuse onto the readers and the streaming
  # writers pull each sink chunk out of its source's read task.
  fx <- fixture_multiband()
  g <- graph_new()
  mk_pred <- function(w_out) {
    bands <- lapply(seq_len(fx$nb), function(b)
      lazy_source(fx$path, band = b, graph = g))
    st <- lazy_stack(bands, along = "band")
    w1 <- matrix(runif(w_out * fx$nb), w_out)
    w2 <- matrix(runif(w_out), 1L)
    reduce_over(st, mlp_project(list(w1, w2), list(rep(0, w_out), 0)),
                over = "band")
  }
  sinks <- list(p8 = mk_pred(8L), p16 = mk_pred(16L))
  p <- plan_lazy(sinks)

  single <- execute_plan(p)

  local_pools(4, 1, gdal_config = TRUE)
  old <- options(garry.placement = "cost", garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  tab <- garry_explain_placement(p)
  expect_true(all(tab$decision == "fuse"))

  # in-memory retrieval from the fused read tasks
  dist <- execute_plan_mirai(p)
  expect_equal(dist$p8, single$p8, tolerance = 1e-12)
  expect_equal(dist$p16, single$p16, tolerance = 1e-12)

  # streamed writes from the fused read tasks
  d <- withr::local_tempdir()
  execute_plan_mirai(p, path = d)
  for (nm in names(sinks)) {
    got <- gdal_read_window(file.path(d, paste0(nm, ".tif")), 1L, 0, 0,
                            ncol(single[[nm]]), nrow(single[[nm]]))
    expect_equal(got, single[[nm]], tolerance = 1e-6, label = nm)
  }
})

test_that("a QA-gated predict (QA as last plane) fuses and matches (the ESD shape)", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  # hutan predict_mlp_lazy's new shape: features + QA in ONE cube, the
  # gate inside mlp_project — single-input, so the big arm can fuse.
  fx <- fixture_multiband()
  g <- graph_new()
  nfe <- fx$nb - 1L
  feats <- lapply(seq_len(nfe), function(b)
    lazy_source(fx$path, band = b, graph = g))
  qa <- lazy_source(fx$path, band = fx$nb, graph = g)
  cube <- lazy_stack(c(feats, list(qa)), along = "band")
  w1 <- matrix(runif(8L * nfe), 8L)
  w2 <- matrix(runif(8L), 1L)
  pred <- reduce_over(cube,
                      mlp_project(list(w1, w2), list(rep(0, 8L), 0),
                                  qa_plane = nfe + 1L, qa_floor = 500),
                      over = "band")
  p <- plan_lazy(list(pred = pred))

  single <- execute_plan(p)
  expect_true(any(is.na(single)))       # the floor gates something
  expect_false(all(is.na(single)))

  local_pools(4, 1, gdal_config = TRUE)
  old <- options(garry.placement = "cost", garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  tab <- garry_explain_placement(p)
  expect_identical(tab$decision, "fuse")
  expect_identical(tab$bands, as.integer(fx$nb))

  dist <- execute_plan_mirai(p)
  expect_equal(dist, single, tolerance = 1e-12)
})

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

test_that("placement tiles a wide pointwise chain and the fused run matches", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  fx <- fixture_multiband()
  g <- graph_new()
  bands <- lapply(seq_len(fx$nb), function(b)
    lazy_source(fx$path, band = b, graph = g))
  st <- lazy_stack(bands, along = "band")
  w1 <- matrix(runif(8L * fx$nb), 8L)
  w2 <- matrix(runif(8L), 1L)
  pred <- reduce_over(st, mlp_project(list(w1, w2),
                                      list(rep(0, 8L), 0)),
                      over = "band")
  p <- plan_lazy(reduce_over(pred * 2, "mean", c("x", "y"),
                             nan_rm = TRUE))
  single <- execute_plan(p)

  local_pools(4, 1, gdal_config = TRUE)
  # a tiny per-call activation budget forces several row tiles
  old <- options(garry.placement = "cost", garry.chunk_target_px = 400,
                 garry.fuse_tile_mb = 1e-4)
  on.exit(options(old), add = TRUE)
  tab <- garry_explain_placement(p)
  mlp <- tab[tab$bands > 1L, ]
  expect_identical(mlp$decision, "fuse")
  expect_true("tiles" %in% names(tab))
  expect_gt(mlp$tiles, 1L)

  dist <- execute_plan_mirai(p)
  expect_equal(dist, single, tolerance = 1e-12)

  # with the default budget the same small window is one tile
  options(garry.fuse_tile_mb = 512)
  tab1 <- garry_explain_placement(p)
  expect_identical(tab1[tab1$bands > 1L, ]$tiles, 1L)
})

test_that("tiling lets a window over fuse_reader_mb fuse instead of materialising", {
  fx <- fixture_multiband()
  g <- graph_new()
  bands <- lapply(seq_len(fx$nb), function(b)
    lazy_source(fx$path, band = b, graph = g))
  st <- lazy_stack(bands, along = "band")
  w1 <- matrix(runif(8L * fx$nb), 8L)
  w2 <- matrix(runif(8L), 1L)
  pred <- reduce_over(st, mlp_project(list(w1, w2),
                                      list(rep(0, 8L), 0)),
                      over = "band")
  p <- plan_lazy(reduce_over(pred * 2, "mean", c("x", "y"),
                             nan_rm = TRUE))
  # reader budget below the whole-window working set but above the
  # input window: untiled it must materialise, tiled it fuses
  old <- options(garry.placement = "cost", garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)
  tab0 <- garry_explain_placement(p, read = 4L, compute = 1L)
  cid <- tab0[tab0$bands > 1L, ]$compute
  C <- p@stages[[cid]]; S <- p@stages[[C@inputs[[1L]]]]
  win_px <- prod(pmin(as.numeric(S@chunks@chunk_dim),
                      as.numeric(S@grid@dims[c("x", "y")])))
  win_rows <- min(S@chunks@chunk_dim[[2L]], S@grid@dims[["y"]])
  options(garry.fuse_tile_mb = 1e9)
  whole <- garry:::.fuse_tiles(p@graph, C, win_px, win_rows, fx$nb)
  options(garry.fuse_tile_mb = whole$act_mb / 8)
  tiled <- garry:::.fuse_tiles(p@graph, C, win_px, win_rows, fx$nb)
  expect_gte(tiled$tiles, 8L)
  expect_lt(tiled$ws_mb, whole$ws_mb)
  # a reader budget between the tiled and the whole working set
  options(garry.fuse_reader_mb = (tiled$ws_mb + whole$ws_mb) / 2)
  options(garry.fuse_tile_mb = 1e9)
  t_un <- garry_explain_placement(p, read = 4L, compute = 1L)
  expect_identical(t_un[t_un$bands > 1L, ]$decision, "comp")
  options(garry.fuse_tile_mb = whole$act_mb / 8)
  t_ti <- garry_explain_placement(p, read = 4L, compute = 1L)
  expect_identical(t_ti[t_ti$bands > 1L, ]$decision, "fuse")
})

test_that(".fuse_tiles keeps a halo chain whole and prices input plus activations", {
  fx <- fixture_multiband()
  g <- graph_new()
  bands <- lapply(seq_len(fx$nb), function(b)
    lazy_source(fx$path, band = b, graph = g))
  st <- lazy_stack(bands, along = "band")
  w1 <- matrix(runif(8L * fx$nb), 8L); w2 <- matrix(runif(8L), 1L)
  pred <- reduce_over(st, mlp_project(list(w1, w2), list(rep(0, 8L), 0)),
                      over = "band")
  p <- plan_lazy(reduce_over(pred * 2, "mean", c("x", "y"), nan_rm = TRUE))
  old <- options(garry.placement = "cost", garry.chunk_target_px = 400,
                 garry.fuse_tile_mb = 1e-4)
  on.exit(options(old), add = TRUE)
  tab <- garry_explain_placement(p, read = 4L, compute = 1L)
  C <- p@stages[[tab[tab$bands > 1L, ]$compute]]
  S <- p@stages[[C@inputs[[1L]]]]
  win_px <- prod(pmin(as.numeric(S@chunks@chunk_dim),
                      as.numeric(S@grid@dims[c("x", "y")])))
  win_rows <- min(S@chunks@chunk_dim[[2L]], S@grid@dims[["y"]])
  tl <- garry:::.fuse_tiles(p@graph, C, win_px, win_rows, fx$nb)
  expect_gt(tl$tiles, 1L)
  # a halo (or out_pad) chain is not tileable: whole window, full activations
  Ch <- C; Ch@halo <- 1L
  th <- garry:::.fuse_tiles(p@graph, Ch, win_px, win_rows, fx$nb)
  expect_identical(th$tiles, 1L)
  expect_equal(th$ws_mb, th$in_mb + th$act_mb)
  Cp <- C; Cp@out_pad <- 1L
  expect_identical(garry:::.fuse_tiles(p@graph, Cp, win_px, win_rows, fx$nb)$tiles, 1L)
  # the input term is host buffer + device copy; activations exclude the copy
  act_px <- garry:::.stage_fuse_act_bytes_px(p@graph, C@members, fx$nb)
  expect_equal(tl$in_mb, win_px * 12 * fx$nb / 2^20)
  expect_equal(tl$act_mb, win_px * (act_px - 4 * fx$nb) / 2^20)
})

# -- seal at a fanned-out reduce ----------------------------------------------

test_that("a fanned-out band reduce fed by a source keeps its own single-export stage", {
  fx <- fixture_multiband()
  mk <- function() {
    g <- graph_new()
    bands <- lapply(seq_len(fx$nb), function(b)
      lazy_source(fx$path, band = b, graph = g))
    st <- lazy_stack(bands, along = "band")
    w1 <- matrix(seq_len(8L * fx$nb) / 100, 8L); w2 <- matrix(seq_len(8L) / 10, 1L)
    reduce_over(st, mlp_project(list(w1, w2), list(rep(0, 8L), 0)), over = "band")
  }
  old <- options(garry.placement = "cost")
  on.exit(options(old), add = TRUE)
  pred <- mk()
  x <- list(a = pred * 2, b = pred + 1,
            c = lazy_map(pred, fn = function(v) sqrt(abs(v)), dtype = "f32"))
  p <- plan_lazy(x)
  own <- Filter(function(s) s@kind == "compute" && pred@node_id %in% s@members,
                p@stages)
  expect_length(own, 1L)
  expect_identical(own[[1L]]@exports, pred@node_id)     # single export
  expect_identical(own[[1L]]@members, pred@node_id)     # consumers cut off
  down <- Filter(function(s) s@kind == "compute" && own[[1L]]@id %in% s@inputs,
                 p@stages)
  expect_length(down, 1L)                               # one downstream stage
  expect_identical(sort(down[[1L]]@exports), sort(unname(p@sinks)))
  # it is a compute-on-read candidate and fuses on a capped pool
  single <- execute_plan(p)
  local_pools(4, 1, gdal_config = TRUE)
  tab <- garry_explain_placement(p)
  expect_identical(tab$compute, own[[1L]]@id)
  expect_identical(tab$decision, "fuse")
  # and the distributed run matches single-process
  dist <- execute_plan_mirai(p)
  for (nm in names(x)) expect_equal(dist[[nm]], single[[nm]], tolerance = 1e-6)

  # ONE consumer: no seal, the map fuses into the reduce's stage as before
  pred1 <- mk()
  p1 <- plan_lazy(pred1 * 2)
  own1 <- Filter(function(s) s@kind == "compute" && pred1@node_id %in% s@members,
                 p1@stages)
  expect_gt(length(own1[[1L]]@members), 1L)

  # rules placement: no seal
  options(garry.placement = "rules")
  pred2 <- mk()
  p2 <- plan_lazy(list(a = pred2 * 2, b = pred2 + 1))
  own2 <- Filter(function(s) s@kind == "compute" && pred2@node_id %in% s@members,
                 p2@stages)
  expect_gt(length(own2[[1L]]@members), 1L)
})
