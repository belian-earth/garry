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
                              open_options = character(0)) {
  H <- cg@halo
  w <- chunk_window_with_halo(cg, core$x_off, core$y_off,
                              core$x_size, core$y_size)
  sub <- tryCatch(
    gdal_read_window(path, band, w$x_off, w$y_off,
                     w$x_size, w$y_size, nodata = nodata,
                     open_options = open_options),
    error = function(e) {
      if (!identical(garry_opt("read_fail"), "nodata")) stop(e)
      warning("read failed, filling with nodata: ", path, " (",
              conditionMessage(e), ")", call. = FALSE)
      matrix(NaN, w$y_size, w$x_size)
    })
  if (H == 0L) return(sub)
  buf <- matrix(NaN, core$y_size + 2L * H, core$x_size + 2L * H)
  r0 <- H - w$pad_top
  c0 <- H - w$pad_left
  buf[(r0 + 1L):(r0 + w$y_size), (c0 + 1L):(c0 + w$x_size)] <- sub
  buf
}

# Trim k cells from every side.
.exec_trim <- function(x, k) {
  if (k == 0L) return(x)
  x[(k + 1L):(nrow(x) - k), (k + 1L):(ncol(x) - k), drop = FALSE]
}

# Output padding a stage's chunks carry: source/warp emit halo-padded
# windows; compute stages consume their padding and emit chunk cores.
.exec_out_pad <- function(stage) {
  if (stage@kind %in% c("source_read", "warp")) stage@halo else 0L
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
# decoupling); the planner only coarsens halo-free stages.
.exec_split_cg <- function(plan, s) {
  cons <- Filter(function(t2)
    s@id %in% t2@inputs &&
      t2@kind %in% c("compute", "reduce_partial"), plan@stages)
  if (length(cons) == 0L) return(NULL)
  cg <- cons[[1L]]@chunks
  if (all(cg@chunk_dim == s@chunks@chunk_dim)) return(NULL)
  stopifnot(s@chunks@halo == 0L,
            all(s@chunks@chunk_dim %% cg@chunk_dim == 0L))
  ChunkGrid(grid = s@grid, chunk_dim = cg@chunk_dim,
            block_dim = s@chunks@block_dim, halo = 0L)
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

# Write sink chunks to a GTiff (shared by both executors). 2D chunks
# write to band 1; (outer, y, x) chunks write one GTiff band per outer
# layer (t or band, D17). Only source/warp sinks carry padding, and
# those are always 2D, so stacked chunks never need trimming.
.exec_write_sink <- function(chunks, it, sink, path, nodata) {
  first <- chunks[[1L]]
  rank3 <- is.array(first) && length(dim(first)) == 3L
  if (nrow(it) == 1L && !is.matrix(first) && !rank3)
    .garry_error("cannot write a scalar reduction to a raster file",
                 "garry_plan_error")
  sink_pad <- .exec_out_pad(sink)
  nodata <- if (is.null(nodata)) numeric(0) else as.numeric(nodata)
  ds <- gdal_create_output(path, sink@grid, nodata = nodata)
  on.exit(ds$close(), add = TRUE)
  for (j in seq_len(nrow(it))) {
    ch <- chunks[[j]]
    if (is.matrix(ch)) {
      gdal_write_window(ds, it$x_off[j], it$y_off[j],
                        .exec_trim(ch, sink_pad),
                        dtype = sink@grid@dtype, nodata = nodata)
    } else {
      stopifnot(sink_pad == 0L)
      for (b in seq_len(dim(ch)[[1L]])) {
        m <- ch[b, , , drop = FALSE]
        dim(m) <- dim(ch)[2:3]
        gdal_write_window(ds, it$x_off[j], it$y_off[j], m,
                          dtype = sink@grid@dtype, nodata = nodata,
                          band = b)
      }
    }
  }
  invisible(path)
}

# Assemble sink chunks into the full raster; stacks assemble to
# (t, y, x) arrays (D17), 2D sinks to [y, x] matrices.
.exec_assemble <- function(chunks, it, grid, sink_pad) {
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
        its <- chunk_iter(split_cg)
        out[[s@id]] <- vector("list", nrow(its))
        for (r in seq_len(nrow(it))) {
          buf <- .exec_read_padded(rpath, rband, rnodata, s@chunks,
                                   it[r, ], open_options = roo)
          for (j in .exec_split_members(its, it[r, ])) {
            r0 <- its$y_off[[j]] - it$y_off[[r]]
            c0 <- its$x_off[[j]] - it$x_off[[r]]
            out[[s@id]][[j]] <- stats::setNames(list(
              buf[(r0 + 1L):(r0 + its$y_size[[j]]),
                  (c0 + 1L):(c0 + its$x_size[[j]]), drop = FALSE]), key)
          }
        }
      }

    } else if (s@kind %in% c("compute", "reduce_partial")) {
      jf <- g_jit(s@fn)
      in_meta <- .exec_in_meta(graph, s, plan@stages)
      shapes <- character(0)
      out[[s@id]] <- lapply(seq_len(nrow(it)), function(j) {
        inputs <- lapply(seq_along(s@input_nodes), function(k) {
          meta <- in_meta[[k]]
          v <- out[[meta$id]][[j]][[.key(s@input_nodes[[k]])]]
          extra <- meta$pad - s@halo
          stopifnot(extra >= 0L)
          g_upload(.exec_trim(v, extra), meta$dtype)
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
