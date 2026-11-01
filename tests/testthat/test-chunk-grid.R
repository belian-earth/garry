# Decision D4 lock: chunk enumeration tiles exactly, halo windows clip
# correctly, and a regular chunk grid never produces more than 4 distinct
# chunk shapes (so no pad-to-uniform is needed anywhere downstream).

.random_chunk_grid <- function(nx, ny, cx, cy, halo = 0L) {
  g <- grid_spec("EPSG:3857",
                 extent = c(0, -(ny), nx, 0),
                 dims    = c(nx, ny))
  ChunkGrid(grid = g, chunk_dim = c(cx, cy),
            block_dim = c(1L, 1L), halo = as.integer(halo))
}

# Total area, contiguous non-overlapping full coverage per axis, and at most
# 4 distinct shapes, labelled consistently.
.expect_tiles <- function(nx, ny, cx, cy) {
  it <- chunk_iter(.random_chunk_grid(nx, ny, cx, cy))
  expect_identical(sum(it$x_size * it$y_size), as.integer(nx * ny))

  xs <- unique(it[order(it$x_off), c("x_off", "x_size")])
  expect_identical(xs$x_off[1], 0L)
  expect_identical(xs$x_off + xs$x_size,
                   c(xs$x_off[-1], as.integer(nx)))
  ys <- unique(it[order(it$y_off), c("y_off", "y_size")])
  expect_identical(ys$y_off[1], 0L)
  expect_identical(ys$y_off + ys$y_size,
                   c(ys$y_off[-1], as.integer(ny)))

  shapes <- unique(it[, c("x_size", "y_size", "shape_id")])
  expect_lte(nrow(shapes), 4L)
  expect_identical(
    it$shape_id,
    ifelse(it$x_size < min(cx, nx) & it$y_size < min(cy, ny), "corner",
    ifelse(it$x_size < min(cx, nx), "right",
    ifelse(it$y_size < min(cy, ny), "bottom", "interior")))
  )
}

# One chunk's window stays on the grid, and its pads reconstruct it.
.expect_window <- function(cg, it, j, h) {
  w <- chunk_window_with_halo(cg, it$x_off[j], it$y_off[j],
                              it$x_size[j], it$y_size[j])
  nx <- cg@grid@dims[["x"]]
  ny <- cg@grid@dims[["y"]]
  expect_gte(w$x_off, 0L); expect_gte(w$y_off, 0L)
  expect_lte(w$x_off + w$x_size, nx)
  expect_lte(w$y_off + w$y_size, ny)
  # Pads + core reconstruct the padded window.
  expect_identical(w$x_size,
                   w$pad_left + it$x_size[j] + w$pad_right)
  expect_identical(w$y_size,
                   w$pad_top + it$y_size[j] + w$pad_bottom)
  # Pads never exceed the halo.
  expect_lte(max(w$pad_left, w$pad_right, w$pad_top, w$pad_bottom), h)
}

test_that("chunks tile the grid exactly (property, 50 draws)", {
  set.seed(42)
  for (i in 1:50) {
    .expect_tiles(sample(1:500, 1), sample(1:500, 1), sample(1:200, 1), sample(1:200, 1))
  }
})

test_that("chunks tile the grid where the arithmetic has corners", {
  .expect_tiles(1L, 1L, 1L, 1L)       # one cell
  .expect_tiles(1L, 7L, 3L, 3L)       # one column, chunked
  .expect_tiles(7L, 5L, 7L, 5L)       # a chunk the size of the grid
  .expect_tiles(7L, 5L, 200L, 200L)   # a chunk past the grid
  .expect_tiles(12L, 8L, 4L, 4L)      # an exact multiple: no edge chunks
  .expect_tiles(13L, 9L, 4L, 4L)      # one cell past it
})

test_that("halo windows clip at edges and pads reconstruct (property)", {
  set.seed(43)
  for (i in 1:25) {
    nx <- sample(5:200, 1); ny <- sample(5:200, 1)
    cx <- sample(2:64, 1);  cy <- sample(2:64, 1)
    h  <- sample(0:5, 1)
    cg <- .random_chunk_grid(nx, ny, cx, cy, h)
    it <- chunk_iter(cg)
    # Check a random subset of chunks per draw.
    for (j in sample(nrow(it), min(5, nrow(it)))) {
      .expect_window(cg, it, j, h)
    }
  }
})

test_that("halo windows hold where the arithmetic has corners", {
  for (case in list(
    list(1L, 1L, 1L, 1L, 3L),     # a halo past the raster
    list(9L, 6L, 2L, 2L, 5L),     # a halo past the chunk
    list(6L, 6L, 6L, 6L, 2L),     # a chunk the size of the grid
    list(5L, 3L, 64L, 64L, 1L)    # a chunk past the grid
  )) {
    cg <- do.call(.random_chunk_grid, case)
    it <- chunk_iter(cg)
    for (j in seq_len(nrow(it))) {
      .expect_window(cg, it, j, case[[5L]])
    }
  }
})

test_that("snap_to_blocks is idempotent, >= block, and a block multiple", {
  set.seed(44)
  for (i in 1:25) {
    chunk <- sample(1:1000, 2)
    block <- sample(1:256, 2)
    s <- snap_to_blocks(chunk, block)
    expect_identical(snap_to_blocks(s, block), s)
    expect_true(all(s >= block))
    expect_true(all(s %% block == 0L))
    expect_true(all(s >= chunk | s == block))
  }
})
