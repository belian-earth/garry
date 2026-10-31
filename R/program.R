#' @include options.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Kernels as programs (design/stablehlo-kernels.md, a spike). Every garry
# kernel is anvl, so it lowers to StableHLO: the host traces a kernel once
# per input shape and a daemon compiles the text. Nothing about the
# closure, the graph or the caller's frames crosses a process, and the
# trace is paid once rather than once per daemon.
#
# A program SET is one kernel over the input shapes its tasks will meet:
# a named list (shape key -> list(src, constants)) of class
# garry_programs. A daemon compiles a shape the first time it meets it.
# ---------------------------------------------------------------------------

.kernel_wire_program <- function() {
  identical(garry_opt("kernel_wire"), "program") &&
    identical(garry_opt("device"), "cpu")
}

# The set for `fn` over `shape_sets` (a list of per-input shape lists),
# built once per host session: tiles of one shape share it. A host-side
# cache, so a run only traces what no earlier run has. Oldest sets go
# first past .program_memo_mb: constants live here as R data.
.program_memo_mb <- 1024

.program_set <- function(key, fn, dtypes, shape_sets) {
  memo <- .garry_state$programs
  if (is.null(memo)) {
    memo <- new.env(parent = emptyenv())
    .garry_state$programs <- memo
    .garry_state$program_order <- character(0)
  }
  hit <- memo[[key]]
  if (!is.null(hit)) {
    return(hit)
  }
  t0 <- proc.time()[["elapsed"]]
  wire <- vapply(dtypes, .input_dtype, character(1))
  set <- structure(
    stats::setNames(
      lapply(shape_sets, function(sh) .program_build(fn, dtypes, sh)),
      vapply(shape_sets, function(sh) .input_key(wire, sh), character(1))
    ),
    class = "garry_programs"
  )
  .garry_state$trace_s <- (.garry_state$trace_s %||% 0) +
    proc.time()[["elapsed"]] - t0
  attr(set, "mb") <- as.numeric(utils::object.size(unclass(set))) / 2^20
  memo[[key]] <- set
  .garry_state$program_order <- c(.garry_state$program_order, key)
  held <- function(k) attr(memo[[k]], "mb") %||% 0
  while (
    length(.garry_state$program_order) > 1L &&
      sum(vapply(.garry_state$program_order, held, numeric(1))) >
        .program_memo_mb
  ) {
    rm(list = .garry_state$program_order[[1L]], envir = memo)
    .garry_state$program_order <- .garry_state$program_order[-1L]
  }
  set
}

# What a set's inputs and anvl's default dtypes pin down: both decide the
# program, and neither is in a stage's kernel signature.
.program_tag <- function(dtypes, shape_sets) {
  wire <- vapply(dtypes, .input_dtype, character(1))
  paste0(
    paste(
      vapply(shape_sets, function(sh) .input_key(wire, sh), character(1)),
      collapse = ";"
    ),
    "#",
    paste(unlist(getOption("anvl.default_dtypes")), collapse = ",")
  )
}

# The dtype a stage input reaches its kernel as. The store keeps a float
# export raw, as the kernel made it, whatever the graph declares
# (.sv_download_exports, .sv_upload): lazy_map() declares its input's
# dtype unless told otherwise. Anything else returns as R data and
# uploads at the declared dtype.
.stored_dtype <- function(made, declared) {
  if (
    !is.null(made) &&
      made$dtype %in% c("f32", "f64") &&
      length(made$shape) >= 2L
  ) {
    made$dtype
  } else {
    declared
  }
}

# `in_meta` with each input's dtype as it will arrive. `made` holds what
# the stages upstream really produce, from their traces.
.stage_inputs <- function(s, in_meta, made) {
  Map(
    function(m, nid) {
      m$dtype <- .stored_dtype(made[[.key(nid)]], m$dtype)
      m
    },
    in_meta,
    s@input_nodes
  )
}

# Note what a traced set produces, by export. A nested export is a
# reduce_partial's, which no kernel consumes.
.note_outputs <- function(made, keys, set) {
  p <- unclass(set)[[1L]]
  for (i in seq_along(keys)) {
    leaf <- p$out_shape[[i]]
    if (!is.list(leaf)) {
      made[[keys[[i]]]] <- p$out_avals[[leaf]]
    }
  }
  invisible(NULL)
}

# The input shapes a stage's tasks meet: the modal chunk when edges grow
# to it, else every distinct chunk shape. A producer's outer dims come
# from its trace; a read has them from its grid, flat when they multiply
# to one.
.stage_shape_sets <- function(graph, s, need, grows, made) {
  outers <- lapply(s@input_nodes, function(nid) {
    real <- made[[.key(nid)]]
    if (!is.null(real)) {
      return(utils::head(as.integer(real$shape), -2L))
    }
    d <- .node_grid(graph_get(graph, nid))@dims
    ob <- as.integer(d[!names(d) %in% c("x", "y")])
    if (prod(ob) > 1L) ob else integer(0)
  })
  it <- unique(chunk_iter(s@chunks)[, c("y_size", "x_size"), drop = FALSE])
  if (grows) {
    cd <- .modal_chunk(s@chunks)
    it <- data.frame(y_size = cd[[2L]], x_size = cd[[1L]])
  }
  lapply(seq_len(nrow(it)), function(i) {
    nr <- it$y_size[[i]] + 2L * need
    nc <- it$x_size[[i]] + 2L * need
    lapply(outers, function(ob) c(ob, nr, nc))
  })
}

# Trace a kernel on the host. Its failure is the task's failure, as it
# would have been on a daemon.
.trace_kernel <- function(key, fn, dtypes, sets, stage) {
  tryCatch(
    .program_set(key, fn, dtypes, sets),
    error = function(e) {
      why <- conditionMessage(e)
      cli::cli_abort(
        "kernel of stage {stage} failed: {why}",
        class = c("garry_task_error", "garry_error"),
        task = paste0("s", stage),
        stage = stage,
        call = NULL
      )
    }
  )
}

# A compute stage's program set, and a key for its inputs. Notes what it
# produces for the stages downstream.
.stage_as_program <- function(graph, s, in_meta, need, grows, made) {
  sets <- .stage_shape_sets(graph, s, need, grows, made)
  dtypes <- vapply(in_meta, function(m) m$dtype, character(1))
  shapes <- .program_tag(dtypes, sets)
  set <- .trace_kernel(
    paste0(.stage_kernel_sig(graph, s), "#", shapes),
    s@fn,
    dtypes,
    sets,
    s@id
  )
  .note_outputs(made, vapply(s@exports, .key, character(1)), set)
  list(set = set, shapes = shapes)
}

# A fused read's spec with its kernel as a program set: one shape per read
# window, and per row-tile height where the kernel runs in tiles.
.fuse_as_program <- function(fspec, graph, src, grows, made) {
  cd <- .modal_chunk(src@chunks)
  halo <- src@chunks@halo
  nb <- .node_outer_nb(graph, src@members[[1L]])
  wins <- unique(
    chunk_iter(src@chunks)[, c("y_size", "x_size"), drop = FALSE]
  )
  if (grows) {
    wins <- data.frame(y_size = cd[[2L]], x_size = cd[[1L]])
  }
  tiles <- as.integer(fspec$tiles %||% 1L)
  sets <- list()
  for (i in seq_len(nrow(wins))) {
    ny <- wins$y_size[[i]] + 2L * halo
    nx <- wins$x_size[[i]] + 2L * halo
    t2 <- max(1L, min(tiles, ny))
    for (h in unique(c(ny %/% t2, ny %/% t2 + (ny %% t2 > 0L)))) {
      sets[[length(sets) + 1L]] <- list(
        if (nb > 1L) c(as.integer(nb), h, nx) else c(h, nx)
      )
    }
  }
  key <- paste0(fspec$ck, "#", .program_tag(fspec$dtype, sets))
  set <- .trace_kernel(key, fspec$fn, fspec$dtype, sets, src@id)
  .note_outputs(made, fspec$out_key, set)
  fspec$fn <- set
  fspec$ck <- key
  fspec
}

# What a daemon runs: a jitted closure, or a program set compiled from
# its text. Either way a function of a list of arrays, returning a list.
.kernel_of <- function(fn, device = NULL) {
  if (inherits(fn, "garry_programs")) .program_kernel(fn, device) else g_jit(fn, device = device)
}
