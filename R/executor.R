#' @include passes.R gdal_adapter.R ops.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Single-threaded anvl-native executor (Phase 5; decision D14).
#
# Topo-walk over stages. Per chunk:
#   read (halo-padded GDAL window) -> upload once -> run the jit()'d
#   stage closure (intermediates stay device-side inside the XLA
#   program) -> download at the stage boundary.
#
# anvl's shape/dtype-keyed LRU jit cache IS the kernel cache: a regular
# chunk grid yields at most 4 shapes per stage (D4), so each stage
# compiles at most 4 executables. reduce_combine runs in plain R on the
# small per-chunk partials. mirai distribution is Phase 7; GDAL write
# sinks are Phase 4b.
# ---------------------------------------------------------------------------

# Read one halo-padded chunk from a GDAL source into a NaN-initialised
# buffer of exactly (y + 2H) x (x + 2H): cells beyond the raster edge
# stay NaN (nodata boundary, D8).
.exec_read_padded <- function(path, band, nodata, cg, core,
                              open_options = character(0),
                              out = c("matrix", "raw_f32")) {
  out <- match.arg(out)
  H <- cg@halo
  # Raw store payloads (D19) only take the halo-free path: padding
  # embeds into a matrix buffer below.
  stopifnot(out == "matrix" || H == 0L)
  w <- chunk_window_with_halo(cg, core$x_off, core$y_off,
                              core$x_size, core$y_size)
  sub <- tryCatch(
    gdal_read_window(path, band, w$x_off, w$y_off,
                     w$x_size, w$y_size, nodata = nodata,
                     open_options = open_options, out = out),
    error = function(e) {
      if (!identical(garry_opt("read_fail"), "nodata")) stop(e)
      warning("read failed, filling with nodata: ", path, " (",
              conditionMessage(e), ")", call. = FALSE)
      if (out == "raw_f32") {
        .sv_from_vec(rep(NaN, w$y_size * w$x_size), w$y_size, w$x_size)
      } else {
        matrix(NaN, w$y_size, w$x_size)
      }
    })
  if (H == 0L) return(sub)
  buf <- matrix(NaN, core$y_size + 2L * H, core$x_size + 2L * H)
  r0 <- H - w$pad_top
  c0 <- H - w$pad_left
  buf[(r0 + 1L):(r0 + w$y_size), (c0 + 1L):(c0 + w$x_size)] <- sub
  buf
}

# Trim k cells from every side (matrix or raw store value).
.exec_trim <- function(x, k) {
  if (k == 0L) return(x)
  if (.sv_is(x)) return(.sv_trim(x, k))
  x[(k + 1L):(nrow(x) - k), (k + 1L):(ncol(x) - k), drop = FALSE]
}

# -- Raw f32 store values (phase 12c, decisions D19/D20) ----------------------
#
# A raw store value is a raw vector holding the f32 byte payload of a
# `[y, x]` window in ROW-major element order, tagged with `gdim`
# (c(nr, nc)) and `gdt` ("f32") attributes. Row-major matches GDAL's
# RasterIO buffer order (reads skip the matrix(byrow = TRUE)
# transpose) and XLA's default layout (uploads skip the relayout
# copy). Only f32 values take this form (D21); everything else stays
# an R matrix, and every store consumer dispatches on .sv_is().

.sv_is <- function(v) is.raw(v) && !is.null(attr(v, "gdim"))

.sv_dim <- function(v) attr(v, "gdim")

# Wrap a ROW-major numeric vector (GDAL read order) as an f32 payload.
.sv_from_vec <- function(v, nr, nc) {
  structure(writeBin(as.numeric(v), raw(), size = 4L),
            gdim = c(nr, nc), gdt = "f32")
}

# Producer-side window slice. `v` is private (fresh read output), so
# the byte-matrix view (one column per row of the image) costs one
# dim-stamped copy for the whole window, amortised over its parts.
.sv_slicer <- function(v) {
  d <- .sv_dim(v)
  bm <- unclass(v)
  attributes(bm) <- NULL
  dim(bm) <- c(4L * d[[2L]], d[[1L]])
  function(r0, c0, nr, nc) {
    out <- bm[(4L * c0 + 1L):(4L * (c0 + nc)), (r0 + 1L):(r0 + nr),
              drop = FALSE]
    attributes(out) <- NULL
    structure(out, gdim = c(nr, nc), gdt = "f32")
  }
}

# Consumer-side halo trim. Consumers hold shared (mori) payloads whose
# attributes must not be touched (a write would force a private copy of
# the whole mapping element), so this gathers by byte index instead of
# taking a dim-stamped view. Trims are 0 on the fused hot paths; this
# runs on align-style plans only.
.sv_trim <- function(v, k) {
  k <- as.integer(k)
  d <- .sv_dim(v)
  nr <- d[[1L]] - 2L * k
  nc <- d[[2L]] - 2L * k
  ncb <- 4L * d[[2L]]
  rows0 <- (k + seq_len(nr) - 1L) * ncb
  cols <- 4L * k + seq_len(4L * nc)
  out <- v[rep(rows0, each = length(cols)) + cols]
  attributes(out) <- NULL
  structure(out, gdim = c(nr, nc), gdt = "f32")
}

# Raw payload -> `[y, x]` matrix (sink writes, collect assembly,
# oracle comparisons).
.sv_to_matrix <- function(v) {
  d <- .sv_dim(v)
  matrix(readBin(v, numeric(), n = prod(d), size = 4L),
         nrow = d[[1L]], byrow = TRUE)
}

# Raw payload -> R array of any rank (row-major payload into R's
# column-major memory). Lists recurse (reduce_partial exports nest);
# non-store values pass through.
.sv_materialise <- function(v) {
  if (is.list(v)) return(lapply(v, .sv_materialise))
  if (!.sv_is(v)) return(v)
  d <- .sv_dim(v)
  if (length(d) == 2L) return(.sv_to_matrix(v))
  x <- readBin(v, numeric(), n = prod(d), size = 4L)
  aperm(array(x, dim = rev(d)), rev(seq_along(d)))
}

# Raw payload -> ROW-major numeric vector (GDAL write order).
.sv_to_vec <- function(v) {
  readBin(v, numeric(), n = prod(.sv_dim(v)), size = 4L)
}

# Upload a store value (raw or matrix) after trimming `k`.
.sv_upload <- function(v, k, dtype, dev) {
  if (.sv_is(v)) {
    v <- .exec_trim(v, k)
    g_upload_raw(v, "f32", .sv_dim(v), device = dev)
  } else {
    g_upload(.exec_trim(v, k), dtype, device = dev)
  }
}

# Download a stage's exports as store values: f32 exports of rank >= 2
# become raw payloads (no double materialisation); scalars and
# non-float exports stay R arrays. Recurses into nested exports
# (reduce_partial wraps its pieces in a list).
.sv_download_exports <- function(res, store_raw) {
  if (!store_raw) return(g_download(res))
  conv <- function(o) {
    if (.g_traced(o)) {
      if (identical(.g_dtype(o), "f32") && length(.g_shape(o)) >= 2L) {
        g_download_raw(o)
      } else {
        g_download(o)
      }
    } else if (is.list(o)) {
      lapply(o, conv)
    } else {
      o
    }
  }
  lapply(res, conv)
}

# Should this run's store hold raw f32 payloads? Resolved once on the
# host and shipped inside task payloads (daemon processes do not
# inherit host options, and the daemons' anvl is assumed to match the
# host's lib path).
.exec_use_raw_store <- function() {
  mode <- match.arg(garry_opt("store_values"), c("auto", "raw", "double"))
  switch(mode,
    double = FALSE,
    raw = TRUE,
    auto = .g_has_raw_upload()
  )
}

# Output padding a stage's chunks carry: source/warp emit halo-padded
# windows; compute stages consume their padding and emit chunk cores.
.exec_out_pad <- function(stage) {
  if (stage@kind %in% c("source_read", "warp")) stage@halo else 0L
}

# Stage device -> anvl device argument: "cpu" means anvl's default
# device (NULL), anything else passes through (e.g. "cuda").
.exec_device <- function(device) {
  if (identical(device, "cpu")) NULL else device
}

# Per-input fetch metadata for a compute/reduce_partial stage. Stage
# outputs are always stored at the plan-wide compute chunk granularity
# (coarse source reads split on write), so consumers index by chunk.
.exec_in_meta <- function(graph, s, plan_stages) {
  producer_of <- function(nid) {
    Find(function(p) nid %in% p@members, plan_stages)
  }
  lapply(s@input_nodes, function(nid) {
    prod <- producer_of(nid)
    list(id = prod@id, pad = .exec_out_pad(prod),
         dtype = graph_get(graph, nid)@grid@dtype)
  })
}

# Split table for a coarse-reading source/warp stage: the consumer's
# (finer) chunk table on the producer's grid, or NULL when tables
# already agree. Read tasks read at their own coarse granularity and
# write one store value per compute chunk (read-granularity
# decoupling). The stage halo rides on both the coarse window and
# every split part: parts are emitted halo-padded (the returned
# table's halo says by how much), which is contained in the coarse
# padded buffer because coarse chunks are unions of whole compute
# chunks.
.exec_split_cg <- function(plan, s) {
  cons <- Filter(function(t2)
    s@id %in% t2@inputs &&
      t2@kind %in% c("compute", "reduce_partial"), plan@stages)
  if (length(cons) == 0L) return(NULL)
  cg <- cons[[1L]]@chunks
  if (all(cg@chunk_dim == s@chunks@chunk_dim)) return(NULL)
  stopifnot(all(s@chunks@chunk_dim %% cg@chunk_dim == 0L))
  ChunkGrid(grid = s@grid, chunk_dim = cg@chunk_dim,
            block_dim = s@chunks@block_dim, halo = s@chunks@halo)
}

# Compute-chunk rows covered by read-chunk row `r` (both tile the same
# grid; read boundaries land on compute boundaries).
.exec_split_members <- function(its, rrow) {
  which(its$x_off >= rrow$x_off &
        its$x_off < rrow$x_off + rrow$x_size &
        its$y_off >= rrow$y_off &
        its$y_off < rrow$y_off + rrow$y_size)
}

# Stage execution/launch order: depth-first postorder from the sink
# over stage inputs. Stage ids are creation-ordered, not topologically
# ordered (fusion can attach a later-created source stage as an input
# to an earlier compute stage), so execution must follow dependencies.
# Postorder adds the guarantee the distributed scheduler's overlap
# depends on: a consumer's ENTIRE producer subtree enqueues
# contiguously, sibling subtrees in input-id order, never interleaved.
# For a multi-band plan (per-band reductions joined by a band stack)
# band k's reads all launch before band k+1's, so each band's fused
# tail overlaps the next band's read drain. This was previously an
# accident of graph-build order; it is now an invariant (dask.order
# solves the same problem with static priorities), gated by
# test-launch-order.R.
.stage_launch_order <- function(plan) {
  n <- length(plan@stages)
  state <- integer(n)          # 0 unvisited, 1 on stack, 2 emitted
  ord <- integer(n)
  pos <- 0L
  visit <- function(i) {
    if (state[[i]] == 2L) return(invisible(NULL))
    if (state[[i]] == 1L)
      .garry_error("stage graph has a cycle", "garry_plan_error")
    state[[i]] <<- 1L
    for (j in plan@stages[[i]]@inputs) visit(j)
    state[[i]] <<- 2L
    pos <<- pos + 1L
    ord[[pos]] <<- i
    invisible(NULL)
  }
  visit(plan@sink)
  # Completeness: stages unreachable from the sink (none in current
  # plans) still execute, after the sink's subtree.
  for (i in seq_len(n)) if (state[[i]] != 2L) visit(i)
  ord
}

# Write one sink chunk to an open output dataset. 2D chunks write to
# band 1; (outer, y, x) chunks write one GTiff band per outer layer
# (t or band, D17). Only source/warp sinks carry padding, and those
# are always 2D, so stacked chunks never need trimming.
.exec_write_chunk <- function(ds, x_off, y_off, ch, sink_pad, dtype,
                              nodata) {
  if (.sv_is(ch)) {
    d <- .sv_dim(ch)
    if (length(d) == 2L) {
      gdal_write_window(ds, x_off, y_off, .exec_trim(ch, sink_pad),
                        dtype = dtype, nodata = nodata)
    } else {
      # Row-major (band, y, x) payload: each band's plane is one
      # contiguous byte range.
      stopifnot(sink_pad == 0L, length(d) == 3L)
      plane <- 4L * prod(d[2:3])
      for (b in seq_len(d[[1L]])) {
        bytes <- ch[((b - 1L) * plane + 1L):(b * plane)]
        gdal_write_window(ds, x_off, y_off,
                          structure(bytes, gdim = d[2:3], gdt = "f32"),
                          dtype = dtype, nodata = nodata, band = b)
      }
    }
  } else if (is.matrix(ch)) {
    gdal_write_window(ds, x_off, y_off, .exec_trim(ch, sink_pad),
                      dtype = dtype, nodata = nodata)
  } else {
    stopifnot(sink_pad == 0L)
    for (b in seq_len(dim(ch)[[1L]])) {
      m <- ch[b, , , drop = FALSE]
      dim(m) <- dim(ch)[2:3]
      gdal_write_window(ds, x_off, y_off, m, dtype = dtype,
                        nodata = nodata, band = b)
    }
  }
  invisible(NULL)
}

.exec_check_writable <- function(ch, n_chunks) {
  if (.sv_is(ch)) {
    if (n_chunks == 1L && length(.sv_dim(ch)) < 2L)
      .garry_error("cannot write a scalar reduction to a raster file",
                   "garry_plan_error")
    return(invisible(NULL))
  }
  rank3 <- is.array(ch) && length(dim(ch)) == 3L
  if (n_chunks == 1L && !is.matrix(ch) && !rank3)
    .garry_error("cannot write a scalar reduction to a raster file",
                 "garry_plan_error")
}

# Write sink chunks to a GTiff (single-threaded executor; the
# distributed scheduler streams chunks through .exec_write_chunk as
# they land instead).
.exec_write_sink <- function(chunks, it, sink, path, nodata) {
  .exec_check_writable(chunks[[1L]], nrow(it))
  sink_pad <- .exec_out_pad(sink)
  nodata <- if (is.null(nodata)) numeric(0) else as.numeric(nodata)
  ds <- gdal_create_output(path, sink@grid, nodata = nodata)
  on.exit(ds$close(), add = TRUE)
  for (j in seq_len(nrow(it))) {
    .exec_write_chunk(ds, it$x_off[j], it$y_off[j], chunks[[j]],
                      sink_pad, sink@grid@dtype, nodata)
  }
  invisible(path)
}

# Assemble sink chunks into the full raster; stacks assemble to
# (t, y, x) arrays (D17), 2D sinks to [y, x] matrices.
.exec_assemble <- function(chunks, it, grid, sink_pad) {
  chunks <- lapply(chunks, .sv_materialise)
  dims <- grid@dims
  outer_dims <- dims[!names(dims) %in% c("x", "y")]
  if (length(outer_dims) == 0L) {
    full <- matrix(NA_real_, dims[["y"]], dims[["x"]])
    for (j in seq_len(nrow(it))) {
      full[(it$y_off[j] + 1L):(it$y_off[j] + it$y_size[j]),
           (it$x_off[j] + 1L):(it$x_off[j] + it$x_size[j])] <-
        .exec_trim(chunks[[j]], sink_pad)
    }
    return(full)
  }
  stopifnot(length(outer_dims) == 1L, sink_pad == 0L)
  full <- array(NA_real_, c(outer_dims[[1L]], dims[["y"]], dims[["x"]]))
  for (j in seq_len(nrow(it))) {
    full[, (it$y_off[j] + 1L):(it$y_off[j] + it$y_size[j]),
         (it$x_off[j] + 1L):(it$x_off[j] + it$x_size[j])] <- chunks[[j]]
  }
  full
}

#' Execute a Plan on the anvl backend (single-threaded).
#'
#' @param plan A `Plan`.
#' @param path Optional GTiff destination: the sink raster is written
#'   chunk by chunk instead of returned in memory.
#' @param nodata Optional sentinel recorded in the output and used to
#'   demote NaN on write (required for integer outputs containing NaN).
#' @return The sink stage's value (matrix for raster sinks, scalar for
#'   global reductions), or `path` invisibly when writing. When
#'   `options(garry.exec_stats = TRUE)`, in-memory results carry a
#'   `garry_exec_stats` attribute with the distinct input shapes
#'   submitted per stage (kernel-cache accounting).
#' @export
execute_plan <- function(plan, path = NULL, nodata = NULL) {
  .require_anvl()
  graph <- plan@graph
  out <- vector("list", length(plan@stages))
  stats <- lapply(plan@stages, function(s) character(0))

  # A source stage consumed only by warp stages never needs reading:
  # the warper pulls pixels from the file itself.
  warp_only <- vapply(plan@stages, function(s) {
    consumers <- Filter(function(t2) s@id %in% t2@inputs, plan@stages)
    s@kind == "source_read" && length(consumers) > 0L &&
      all(vapply(consumers, function(t2) t2@kind == "warp", logical(1))) &&
      plan@sink != s@id
  }, logical(1))

  for (s in plan@stages[.stage_launch_order(plan)]) {
    it <- chunk_iter(s@chunks)

    if (s@kind %in% c("source_read", "warp")) {
      if (s@kind == "source_read" && warp_only[[s@id]]) next
      if (s@kind == "warp") {
        wnode <- graph_get(graph, s@members[[1L]])
        snode <- graph_get(graph, wnode@parents[[1L]])
        rpath <- gdal_warp_vrt(snode@path, snode@band, wnode@target_grid,
                               wnode@resampling, src_nodata = snode@nodata)
        rband <- 1L; rnodata <- snode@nodata; roo <- character(0)
        key <- .key(wnode@id)
      } else {
        node <- graph_get(graph, s@members[[1L]])
        rpath <- node@path; rband <- node@band; rnodata <- node@nodata
        roo <- node@open_options
        key <- .key(node@id)
      }
      split_cg <- .exec_split_cg(plan, s)
      if (is.null(split_cg)) {
        out[[s@id]] <- lapply(seq_len(nrow(it)), function(j) {
          stats::setNames(
            list(.exec_read_padded(rpath, rband, rnodata, s@chunks,
                                   it[j, ], open_options = roo)), key)
        })
      } else {
        # Coarse read, split into compute-chunk values on arrival.
        # Parts carry the stage halo: part (r0, c0) offsets are
        # identical with or without halo (both buffer and part
        # windows shift by -halo), only the slice grows by 2*halo.
        its <- chunk_iter(split_cg)
        H2 <- 2L * split_cg@halo
        out[[s@id]] <- vector("list", nrow(its))
        for (r in seq_len(nrow(it))) {
          buf <- .exec_read_padded(rpath, rband, rnodata, s@chunks,
                                   it[r, ], open_options = roo)
          for (j in .exec_split_members(its, it[r, ])) {
            r0 <- its$y_off[[j]] - it$y_off[[r]]
            c0 <- its$x_off[[j]] - it$x_off[[r]]
            out[[s@id]][[j]] <- stats::setNames(list(
              buf[(r0 + 1L):(r0 + its$y_size[[j]] + H2),
                  (c0 + 1L):(c0 + its$x_size[[j]] + H2), drop = FALSE]),
              key)
          }
        }
      }

    } else if (s@kind %in% c("compute", "reduce_partial")) {
      dev <- .exec_device(s@device)
      jf <- g_jit(s@fn, device = dev)
      in_meta <- .exec_in_meta(graph, s, plan@stages)
      shapes <- character(0)
      out[[s@id]] <- lapply(seq_len(nrow(it)), function(j) {
        inputs <- lapply(seq_along(s@input_nodes), function(k) {
          meta <- in_meta[[k]]
          v <- out[[meta$id]][[j]][[.key(s@input_nodes[[k]])]]
          extra <- meta$pad - s@halo
          stopifnot(extra >= 0L)
          g_upload(.exec_trim(v, extra), meta$dtype, device = dev)
        })
        shapes <<- unique(c(shapes, paste(
          vapply(inputs, function(a) paste(dim(a), collapse = "x"),
                 character(1)), collapse = "|")))
        g_download(jf(inputs))
      })
      stats[[s@id]] <- shapes

    } else if (s@kind == "reduce_combine") {
      key <- .key(s@members[[1L]])
      partials <- lapply(out[[s@inputs[[1L]]]], `[[`, key)
      out[[s@id]] <- list(s@fn(partials))

    } else {
      .garry_error(paste0("stage kind not executable: ", s@kind),
                   "garry_not_implemented_error")
    }
  }

  sink <- plan@stages[[plan@sink]]
  key <- .key(sink@members[[length(sink@members)]])
  chunks <- lapply(out[[sink@id]], `[[`, key)
  it <- chunk_iter(sink@chunks)
  # Sink chunks may still carry source/warp output padding.
  sink_pad <- .exec_out_pad(sink)

  if (!is.null(path))
    return(.exec_write_sink(chunks, it, sink, path, nodata))

  result <- if (nrow(it) == 1L) {
    v <- chunks[[1L]]
    if (is.matrix(v)) v <- .exec_trim(v, sink_pad)
    if (is.matrix(v) && all(dim(v) == c(1L, 1L))) v[1L, 1L] else v
  } else {
    .exec_assemble(chunks, it, sink@grid, sink_pad)
  }

  if (isTRUE(getOption("garry.exec_stats", FALSE)))
    attr(result, "garry_exec_stats") <- stats
  result
}
