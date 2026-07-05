# Mini-executor over the pure-R oracle: runs a Plan chunk by chunk with
# source data supplied as R matrices ([y, x], decision D13). This is the
# Phase 3 proof that chunked execution equals whole-array execution,
# independent of anvl. The Phase 5 executor follows the same contracts.

# Read a halo-padded chunk from a full matrix; cells outside the raster
# are NaN (the boundary contract in R/plan.R).
.read_padded <- function(m, cg, core) {
  H <- cg@halo
  w <- chunk_window_with_halo(cg, core$x_off, core$y_off,
                              core$x_size, core$y_size)
  buf <- matrix(NaN, core$y_size + 2L * H, core$x_size + 2L * H)
  sub <- m[(w$y_off + 1L):(w$y_off + w$y_size),
           (w$x_off + 1L):(w$x_off + w$x_size), drop = FALSE]
  r0 <- H - w$pad_top
  c0 <- H - w$pad_left
  buf[(r0 + 1L):(r0 + w$y_size), (c0 + 1L):(c0 + w$x_size)] <- sub
  buf
}

# Trim k cells from every side (producer padded more than this consumer
# needs).
.trim_pad <- function(x, k) {
  if (k == 0L) return(x)
  x[(k + 1L):(nrow(x) - k), (k + 1L):(ncol(x) - k), drop = FALSE]
}

oracle_exec <- function(plan, data) {
  graph <- plan@graph
  out <- vector("list", length(plan@stages))   # per stage: list over chunks

  for (s in plan@stages) {
    it <- chunk_iter(s@chunks)

    if (s@kind == "source_read") {
      node <- graph_get(graph, s@members[[1L]])
      m <- data[[node@path]]
      stopifnot(!is.null(m))
      out[[s@id]] <- lapply(seq_len(nrow(it)), function(j) {
        stats::setNames(list(.read_padded(m, s@chunks, it[j, ])),
                        as.character(s@members[[1L]]))
      })

    } else if (s@kind == "compute" || s@kind == "reduce_partial") {
      out[[s@id]] <- lapply(seq_len(nrow(it)), function(j) {
        inputs <- lapply(seq_along(s@input_nodes), function(k) {
          nid <- s@input_nodes[[k]]
          prod_stage <- Find(function(p) nid %in% p@members, plan@stages)
          v <- out[[prod_stage@id]][[j]][[as.character(nid)]]
          # Output padding: source/warp stages emit halo-padded windows;
          # compute stages consume their padding and emit chunk cores.
          out_pad <- if (prod_stage@kind %in% c("source_read", "warp"))
            prod_stage@halo else 0L
          extra <- out_pad - s@halo
          stopifnot(extra >= 0L)
          .trim_pad(v, extra)
        })
        s@fn(inputs)
      })

    } else if (s@kind == "reduce_combine") {
      part_stage <- plan@stages[[s@inputs[[1L]]]]
      key <- as.character(s@members[[1L]])
      partials <- lapply(out[[part_stage@id]], `[[`, key)
      out[[s@id]] <- list(s@fn(partials))

    } else {
      stop("oracle_exec: unsupported stage kind ", s@kind)
    }
  }

  sink <- plan@stages[[plan@sink]]
  key <- as.character(sink@members[[length(sink@members)]])
  chunks <- lapply(out[[sink@id]], `[[`, key)
  it <- chunk_iter(sink@chunks)
  if (nrow(it) == 1L) return(chunks[[1L]])

  dims <- sink@grid@dims
  full <- matrix(NA_real_, dims[["y"]], dims[["x"]])
  for (j in seq_len(nrow(it))) {
    full[(it$y_off[j] + 1L):(it$y_off[j] + it$y_size[j]),
         (it$x_off[j] + 1L):(it$x_off[j] + it$x_size[j])] <- chunks[[j]]
  }
  full
}
