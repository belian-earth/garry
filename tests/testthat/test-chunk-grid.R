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

test_that("chunks tile the grid exactly (property, 200 draws)", {
  set.seed(42)
  for (i in 1:200) {
    nx <- sample(1:500, 1); ny <- sample(1:500, 1)
    cx <- sample(1:200, 1); cy <- sample(1:200, 1)
    it <- chunk_iter(.random_chunk_grid(nx, ny, cx, cy))

    # Total area matches.
    expect_identical(sum(it$x_size * it$y_size), as.integer(nx * ny))

    # Per-axis: contiguous, non-overlapping, full coverage.
    xs <- unique(it[order(it$x_off), c("x_off", "x_size")])
    expect_identical(xs$x_off[1], 0L)
    expect_identical(xs$x_off + xs$x_size,
                     c(xs$x_off[-1], as.integer(nx)))
    ys <- unique(it[order(it$y_off), c("y_off", "y_size")])
    expect_identical(ys$y_off[1], 0L)
    expect_identical(ys$y_off + ys$y_size,
                     c(ys$y_off[-1], as.integer(ny)))

    # At most 4 distinct shapes, labelled consistently.
    shapes <- unique(it[, c("x_size", "y_size", "shape_id")])
    expect_lte(nrow(shapes), 4L)
    expect_identical(
      it$shape_id,
      ifelse(it$x_size < min(cx, nx) & it$y_size < min(cy, ny), "corner",
      ifelse(it$x_size < min(cx, nx), "right",
      ifelse(it$y_size < min(cy, ny), "bottom", "interior")))
    )
  }
})

test_that("halo windows clip at edges and pads reconstruct (property)", {
  set.seed(43)
  for (i in 1:100) {
    nx <- sample(5:200, 1); ny <- sample(5:200, 1)
    cx <- sample(2:64, 1);  cy <- sample(2:64, 1)
    h  <- sample(0:5, 1)
    cg <- .random_chunk_grid(nx, ny, cx, cy, h)
    it <- chunk_iter(cg)
    # Check a random subset of chunks per draw.
    for (j in sample(nrow(it), min(5, nrow(it)))) {
      w <- chunk_window_with_halo(cg, it$x_off[j], it$y_off[j],
                                  it$x_size[j], it$y_size[j])
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
  }
})

test_that("snap_to_blocks is idempotent, >= block, and a block multiple", {
  set.seed(44)
  for (i in 1:100) {
    chunk <- sample(1:1000, 2)
    block <- sample(1:256, 2)
    s <- snap_to_blocks(chunk, block)
    expect_identical(snap_to_blocks(s, block), s)
    expect_true(all(s >= block))
    expect_true(all(s %% block == 0L))
    expect_true(all(s >= chunk | s == block))
  }
})
