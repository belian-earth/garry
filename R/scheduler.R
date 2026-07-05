#' @include executor.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Distributed executor over mirai daemons (Phase 7, decision D16).
#
# Tasks are keyed (stage_id, chunk_idx). Dependencies: source/warp chunk
# tasks are free; compute/reduce_partial chunk j depends on chunk j of
# each input stage (chunk tables are aligned in v1); reduce_combine and
# final assembly run on the host once their inputs land.
#
# Inter-stage store: one RDS file per (stage, chunk) in a tempdir shared
# by same-host daemons. No mid-graph halo store is needed (D11): halos
# ride inside source/warp chunk files.
#
# Scheduler: polling ready-queue with an in-flight cap (back-pressure).
# Workers jit stage closures on first use and keep them in a per-daemon
# cache, so each daemon compiles each stage's <=4 shapes once (D14).
# ---------------------------------------------------------------------------

# Per-process cache used on daemons (jitted stage closures by stage id).
.daemon_cache <- new.env(parent = emptyenv())

# -- Worker-side task bodies (run on daemons) ---------------------------------

#' Daemon task body: read one padded source chunk into the store.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param path,band,nodata Source identity.
#' @param cg `ChunkGrid`; `core` the chunk row; `key` the node key;
#'   `out_file` the store file.
#' @return `TRUE`.
#' @keywords internal
#' @export
.daemon_run_source <- function(path, band, nodata, cg, core, key,
                               out_file, open_options = character(0)) {
  m <- .exec_read_padded(path, band, nodata, cg, core,
                         open_options = open_options)
  saveRDS(stats::setNames(list(m), key), out_file)
  TRUE
}

#' Daemon task body: run one jitted stage closure on one chunk.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param cache_key Per-run jit cache key.
#' @param fn Stage closure; `in_files`/`in_keys`/`trims`/`dtypes`
#'   describe the inputs; `out_file` the store file.
#' @return `TRUE`.
#' @keywords internal
#' @export
.daemon_run_compute <- function(cache_key, fn, in_files, in_keys, trims,
                                dtypes, out_file) {
  if (length(ls(.daemon_cache)) > 64L)
    rm(list = ls(.daemon_cache), envir = .daemon_cache)
  jf <- .daemon_cache[[cache_key]]
  if (is.null(jf)) {
    jf <- g_jit(fn)
    .daemon_cache[[cache_key]] <- jf
  }
  inputs <- Map(function(f, k, tr, dt) {
    g_upload(.exec_trim(readRDS(f)[[k]], tr), dt)
  }, in_files, in_keys, trims, dtypes)
  res <- g_download(jf(unname(inputs)))
  saveRDS(res, out_file)
  TRUE
}

# -- Host-side scheduler -------------------------------------------------------

#' Execute a Plan across mirai daemons.
#'
#' Requires `mirai::daemons()` to be set by the caller. Results are
#' identical to `execute_plan()` (same plan, same kernels; the
#' equivalence is gate-tested).
#'
#' @param plan A `Plan`.
#' @param path,nodata As in `execute_plan()`.
#' @return As `execute_plan()`.
#' @export
execute_plan_mirai <- function(plan, path = NULL, nodata = NULL) {
  if (!requireNamespace("mirai", quietly = TRUE))
    stop("the mirai package is required for distributed execution")
  st <- mirai::status()
  n_daemons <- if (is.numeric(st$connections)) st$connections else 0L
  if (n_daemons < 1L)
    .garry_error("no mirai daemons: call mirai::daemons(n) first",
                 "garry_scheduler_error")
  cap <- max(2L * n_daemons, 4L)

  # User stage closures call the g_* vocabulary unqualified; make sure
  # the package is attached on every daemon (idempotent, once per call).
  mirai::everywhere(suppressMessages(library(garry)))

  graph <- plan@graph
  run_id <- as.integer(stats::runif(1, 1, 1e8))
  store <- file.path(tempdir(), paste0("garry-store-", run_id))
  dir.create(store, recursive = TRUE)
  on.exit(unlink(store, recursive = TRUE), add = TRUE)
  chunk_file <- function(sid, j) file.path(store, sprintf("s%d_c%d.rds", sid, j))

  producer_of <- function(nid) Find(function(p) nid %in% p@members, plan@stages)

  warp_only <- vapply(plan@stages, function(s) {
    consumers <- Filter(function(t2) s@id %in% t2@inputs, plan@stages)
    s@kind == "source_read" && length(consumers) > 0L &&
      all(vapply(consumers, function(t2) t2@kind == "warp", logical(1))) &&
      plan@sink != s@id
  }, logical(1))

  # Build the task table. Combine stages are host-side, handled at drain.
  tasks <- list()
  add_task <- function(key, deps, launch) {
    tasks[[key]] <<- list(deps = deps, launch = launch, state = "pending")
  }

  for (s in plan@stages) {
    if (s@kind == "reduce_combine") next
    if (s@kind == "source_read" && warp_only[[s@id]]) next
    it <- chunk_iter(s@chunks)

    if (s@kind %in% c("source_read", "warp")) {
      if (s@kind == "warp") {
        wnode <- graph_get(graph, s@members[[1L]])
        snode <- graph_get(graph, wnode@parents[[1L]])
        vrt <- gdal_warp_vrt(snode@path, snode@band, wnode@target_grid,
                             wnode@resampling, src_nodata = snode@nodata)
        rpath <- vrt; rband <- 1L; rnodata <- snode@nodata
        roo <- character(0)
      } else {
        node <- graph_get(graph, s@members[[1L]])
        rpath <- node@path; rband <- node@band; rnodata <- node@nodata
        roo <- node@open_options
      }
      skey <- .key(s@members[[1L]])
      for (j in seq_len(nrow(it))) {
        local({
          sid <- s@id; jj <- j; cg <- s@chunks; core <- it[jj, ]
          p2 <- rpath; b2 <- rband; nd <- rnodata; k2 <- skey; oo <- roo
          add_task(sprintf("s%d_c%d", sid, jj), character(0), function() {
            mirai::mirai(
              garry::.daemon_run_source(p2, b2, nd, cg, core, k2, out,
                                        open_options = oo),
              p2 = p2, b2 = b2, nd = nd, cg = cg, core = core, k2 = k2,
              oo = oo, out = chunk_file(sid, jj))
          })
        })
      }

    } else {  # compute / reduce_partial
      in_meta <- lapply(s@input_nodes, function(nid) {
        prod <- producer_of(nid)
        list(sid = prod@id, pad = .exec_out_pad(prod),
             dtype = graph_get(graph, nid)@grid@dtype)
      })
      for (j in seq_len(nrow(it))) {
        local({
          sid <- s@id; jj <- j; fn <- s@fn; halo <- s@halo
          meta <- in_meta
          ck <- sprintf("r%d_s%d", run_id, sid)   # per-run jit cache key
          deps <- vapply(meta, function(m) sprintf("s%d_c%d", m$sid, jj),
                         character(1))
          in_keys <- vapply(s@input_nodes, .key, character(1))
          add_task(sprintf("s%d_c%d", sid, jj), unique(deps), function() {
            mirai::mirai(
              garry::.daemon_run_compute(ck, fn, in_files, in_keys,
                                          trims, dtypes, out),
              ck = ck, fn = fn,
              in_files = vapply(meta, function(m)
                chunk_file(m$sid, jj), character(1)),
              in_keys = in_keys,
              trims = vapply(meta, function(m)
                as.integer(m$pad - halo), integer(1)),
              dtypes = vapply(meta, function(m) m$dtype, character(1)),
              out = chunk_file(sid, jj))
          })
        })
      }
    }
  }

  # Polling ready-queue with in-flight cap.
  inflight <- list()
  done <- character(0)
  is_ready <- function(t) all(t$deps %in% done)
  remaining <- function() {
    any(vapply(tasks, function(t) t$state != "done", logical(1)))
  }
  while (remaining()) {
    for (k in names(tasks)) {
      if (length(inflight) >= cap) break
      t <- tasks[[k]]
      if (t$state == "pending" && is_ready(t)) {
        inflight[[k]] <- t$launch()
        tasks[[k]]$state <- "running"
      }
    }
    if (length(inflight) == 0L)
      .garry_error("scheduler deadlock: no runnable tasks",
                   "garry_scheduler_error")
    harvested <- FALSE
    for (k in names(inflight)) {
      h <- inflight[[k]]
      if (!mirai::unresolved(h)) {
        if (inherits(h$data, c("miraiError", "errorValue")))
          stop("task ", k, " failed on daemon: ", as.character(h$data))
        tasks[[k]]$state <- "done"
        done <- c(done, k)
        inflight[[k]] <- NULL
        harvested <- TRUE
      }
    }
    if (!harvested) Sys.sleep(0.002)
  }

  # Host-side: combines, then sink retrieval (mirrors execute_plan).
  read_chunk <- function(sid, j) readRDS(chunk_file(sid, j))
  out_of <- function(s) {
    it <- chunk_iter(s@chunks)
    lapply(seq_len(nrow(it)), function(j) read_chunk(s@id, j))
  }

  combine_vals <- new.env(parent = emptyenv())
  for (s in plan@stages) {
    if (s@kind != "reduce_combine") next
    part <- plan@stages[[s@inputs[[1L]]]]
    key <- .key(s@members[[1L]])
    partials <- lapply(out_of(part), `[[`, key)
    combine_vals[[.key(s@id)]] <- s@fn(partials)
  }

  sink <- plan@stages[[plan@sink]]
  key <- .key(sink@members[[length(sink@members)]])
  chunks <- if (sink@kind == "reduce_combine") {
    list(combine_vals[[.key(sink@id)]][[key]])
  } else {
    lapply(out_of(sink), `[[`, key)
  }
  it <- chunk_iter(sink@chunks)
  sink_pad <- .exec_out_pad(sink)

  if (!is.null(path)) {
    if (nrow(it) == 1L && !is.matrix(chunks[[1L]]))
      .garry_error("cannot write a scalar reduction to a raster file",
                   "garry_plan_error")
    nodata <- if (is.null(nodata)) numeric(0) else as.numeric(nodata)
    ds <- gdal_create_output(path, sink@grid, nodata = nodata)
    on.exit(ds$close(), add = TRUE)
    for (j in seq_len(nrow(it))) {
      gdal_write_window(ds, it$x_off[j], it$y_off[j],
                        .exec_trim(chunks[[j]], sink_pad),
                        dtype = sink@grid@dtype, nodata = nodata)
    }
    return(invisible(path))
  }

  if (nrow(it) == 1L) {
    v <- chunks[[1L]]
    if (is.matrix(v)) v <- .exec_trim(v, sink_pad)
    if (is.matrix(v) && all(dim(v) == c(1L, 1L))) return(v[1L, 1L])
    return(v)
  }
  .exec_assemble(chunks, it, sink@grid, sink_pad)
}
