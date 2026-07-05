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
.exec_read_padded <- function(node, cg, core) {
  H <- cg@halo
  w <- chunk_window_with_halo(cg, core$x_off, core$y_off,
                              core$x_size, core$y_size)
  sub <- gdal_read_window(node@path, node@band, w$x_off, w$y_off,
                          w$x_size, w$y_size, nodata = node@nodata)
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

#' Execute a Plan on the anvl backend (single-threaded).
#'
#' @param plan A `Plan`.
#' @return The sink stage's value: a matrix/array for raster sinks, a
#'   scalar for global reductions. When `options(garry.exec_stats =
#'   TRUE)`, the result carries a `garry_exec_stats` attribute with the
#'   distinct input shapes submitted per stage (kernel-cache accounting).
#' @export
execute_plan <- function(plan) {
  .require_anvl()
  graph <- plan@graph
  out <- vector("list", length(plan@stages))
  stats <- lapply(plan@stages, function(s) character(0))

  producer_of <- function(nid) {
    Find(function(p) nid %in% p@members, plan@stages)
  }

  for (s in plan@stages) {
    it <- chunk_iter(s@chunks)

    if (s@kind == "source_read") {
      node <- graph_get(graph, s@members[[1L]])
      key <- .key(node@id)
      out[[s@id]] <- lapply(seq_len(nrow(it)), function(j) {
        stats::setNames(list(.exec_read_padded(node, s@chunks, it[j, ])),
                        key)
      })

    } else if (s@kind %in% c("compute", "reduce_partial")) {
      jf <- g_jit(s@fn)
      in_meta <- lapply(s@input_nodes, function(nid) {
        prod <- producer_of(nid)
        list(id = prod@id, pad = .exec_out_pad(prod),
             dtype = graph_get(graph, nid)@grid@dtype)
      })
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
      .garry_error(paste0("stage kind not executable yet: ", s@kind,
                          " (warp execution arrives in Phase 4b)"),
                   "garry_not_implemented_error")
    }
  }

  sink <- plan@stages[[plan@sink]]
  key <- .key(sink@members[[length(sink@members)]])
  chunks <- lapply(out[[sink@id]], `[[`, key)
  it <- chunk_iter(sink@chunks)

  result <- if (nrow(it) == 1L) {
    v <- chunks[[1L]]
    if (is.matrix(v) && all(dim(v) == c(1L, 1L))) v[1L, 1L] else v
  } else {
    dims <- sink@grid@dims
    full <- matrix(NA_real_, dims[["y"]], dims[["x"]])
    for (j in seq_len(nrow(it))) {
      full[(it$y_off[j] + 1L):(it$y_off[j] + it$y_size[j]),
           (it$x_off[j] + 1L):(it$x_off[j] + it$x_size[j])] <- chunks[[j]]
    }
    full
  }

  if (isTRUE(getOption("garry.exec_stats", FALSE)))
    attr(result, "garry_exec_stats") <- stats
  result
}
