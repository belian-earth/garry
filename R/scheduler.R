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

# Daemon-side registry pinning mori shared-memory regions. A region
# lives only while its creator holds a reference (mori unlinks on GC),
# and task locals die with the task, so every share() lands here until
# the host clears the run (see `garry.store`).
.daemon_shm <- new.env(parent = emptyenv())

#' Daemon task body: release all pinned shared-memory regions.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @return `NULL`, invisibly.
#' @keywords internal
#' @export
.daemon_shm_clear <- function() {
  rm(list = ls(.daemon_shm), envir = .daemon_shm)
  gc(FALSE)
  invisible(NULL)
}

#' Daemon task body: release named shared-memory regions.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param keys Registry keys to drop (missing keys are ignored).
#' @return `NULL`, invisibly.
#' @keywords internal
#' @export
.daemon_shm_drop <- function(keys) {
  keys <- intersect(keys, ls(.daemon_shm))
  if (length(keys) > 0L) {
    rm(list = keys, envir = .daemon_shm)
    gc(FALSE)
  }
  invisible(NULL)
}

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
  # Store files are transient same-host scratch: gzip costs hundreds of
  # ms per chunk and buys nothing.
  saveRDS(stats::setNames(list(m), key), out_file, compress = FALSE)
  TRUE
}

#' Daemon task body: read one coarse source window, split it into
#' per-compute-chunk store files.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param path,band,nodata Source identity.
#' @param cg Read-granularity `ChunkGrid` (halo-free); `core` the read
#'   chunk row; `key` the node key.
#' @param parts List of per-compute-chunk windows: `r0`/`c0` 0-based
#'   offsets within the read buffer, `nr`/`nc` sizes, `file` the store
#'   file.
#' @return `TRUE`.
#' @keywords internal
#' @export
.daemon_run_source_split <- function(path, band, nodata, cg, core, key,
                                     parts, open_options = character(0)) {
  m <- .exec_read_padded(path, band, nodata, cg, core,
                         open_options = open_options)
  for (p in parts) {
    saveRDS(stats::setNames(list(
      m[(p$r0 + 1L):(p$r0 + p$nr), (p$c0 + 1L):(p$c0 + p$nc),
        drop = FALSE]), key), p$file, compress = FALSE)
  }
  TRUE
}

#' Daemon task body: read one source window into shared memory.
#'
#' The mori-store counterpart of `.daemon_run_source` and
#' `.daemon_run_source_split`. Coarse reads share their per-compute-
#' chunk parts as elements of one shared list: consumers extract their
#' element zero-copy. (Consumer-side RANGE subsetting of a mapped
#' matrix would materialise the whole window per input - measured as
#' multi-GB of transient daemon heap on the benchmark - so the split
#' happens producer-side here too.)
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param path,band,nodata Source identity.
#' @param cg `ChunkGrid`; `core` the chunk row; `key` the node key;
#'   `reg_key` the daemon registry slot pinning the region.
#' @param parts NULL for chunk-aligned reads (the buffer is shared
#'   whole under `key`), else per-compute-chunk windows (`r0`/`c0`
#'   0-based offsets, `nr`/`nc` sizes, `elt` the element name).
#' @return The shared object (serialises as its region name).
#' @keywords internal
#' @export
.daemon_run_source_shm <- function(path, band, nodata, cg, core, key,
                                   reg_key, parts = NULL,
                                   open_options = character(0)) {
  m <- .exec_read_padded(path, band, nodata, cg, core,
                         open_options = open_options)
  val <- if (is.null(parts)) stats::setNames(list(m), key) else {
    stats::setNames(
      lapply(parts, function(p)
        m[(p$r0 + 1L):(p$r0 + p$nr), (p$c0 + 1L):(p$c0 + p$nc),
          drop = FALSE]),
      vapply(parts, `[[`, character(1), "elt"))
  }
  sh <- mori::share(val)
  .daemon_shm[[reg_key]] <- sh
  sh
}

#' Daemon task body: run one jitted stage closure on shared-memory
#' inputs.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param cache_key Per-run jit cache key.
#' @param fn Stage closure; `in_vals`/`in_keys`/`trims`/`dtypes`
#'   describe the inputs (`in_keys` name the element to extract from
#'   each shared value: the node key, or a part name for coarse
#'   reads); `reg_key` the daemon registry slot for the result.
#' @return The shared result (serialises as its region name).
#' @keywords internal
#' @export
.daemon_run_compute_shm <- function(cache_key, fn, in_vals, in_keys,
                                    trims, dtypes, reg_key) {
  if (length(ls(.daemon_cache)) > 64L)
    rm(list = ls(.daemon_cache), envir = .daemon_cache)
  jf <- .daemon_cache[[cache_key]]
  if (is.null(jf)) {
    jf <- g_jit(fn)
    .daemon_cache[[cache_key]] <- jf
  }
  inputs <- Map(function(v, k, tr, dt) {
    g_upload(.exec_trim(v[[k]], tr), dt)
  }, in_vals, in_keys, trims, dtypes)
  res <- g_download(jf(unname(inputs)))
  sh <- mori::share(res)
  .daemon_shm[[reg_key]] <- sh
  sh
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
  saveRDS(res, out_file, compress = FALSE)
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
  store_mode <- match.arg(garry_opt("store"), c("rds", "mori"))
  use_shm <- store_mode == "mori"
  if (use_shm && !requireNamespace("mori", quietly = TRUE))
    .garry_error("options(garry.store = \"mori\") needs the mori package",
                 "garry_scheduler_error")
  store <- file.path(tempdir(), paste0("garry-store-", run_id))
  dir.create(store, recursive = TRUE)
  on.exit(unlink(store, recursive = TRUE), add = TRUE)
  if (use_shm) {
    # Daemons pin every region they created for this run; release them
    # once the host is done with the results (regions outlive tasks,
    # not the run). Host-side handles die with `chunk_vals`.
    on.exit(try(mirai::everywhere(garry::.daemon_shm_clear()),
                silent = TRUE), add = TRUE)
  }
  chunk_file <- function(sid, j) file.path(store, sprintf("s%d_c%d.rds", sid, j))
  chunk_vals <- new.env(parent = emptyenv())   # task key -> shared value


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
  # For coarse-reading (split) source stages: task key per compute chunk,
  # and (mori store) each compute chunk's element name in the shared
  # parts list.
  source_deps <- new.env(parent = emptyenv())
  source_elts <- new.env(parent = emptyenv())
  # Mori store: release a read's regions once every stage consuming it
  # has finished (a region shared by several stages - e.g. the QA band
  # - must outlive all of them). Keeps the pinned working set to the
  # stages still running instead of the whole run.
  comp_stage_of <- new.env(parent = emptyenv())  # compute task -> stage
  stage_left <- new.env(parent = emptyenv())     # stage -> open chunks
  stage_reads <- new.env(parent = emptyenv())    # stage -> read tasks
  read_users <- new.env(parent = emptyenv())     # read task -> n stages

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
      split_cg <- .exec_split_cg(plan, s)
      if (is.null(split_cg)) {
        for (j in seq_len(nrow(it))) {
          local({
            sid <- s@id; jj <- j; cg <- s@chunks; core <- it[jj, ]
            p2 <- rpath; b2 <- rband; nd <- rnodata; k2 <- skey; oo <- roo
            key <- sprintf("s%d_c%d", sid, jj)
            add_task(key, character(0), if (use_shm) function() {
              mirai::mirai(
                garry::.daemon_run_source_shm(p2, b2, nd, cg, core, k2,
                                              reg, open_options = oo),
                p2 = p2, b2 = b2, nd = nd, cg = cg, core = core, k2 = k2,
                oo = oo, reg = sprintf("r%d_%s", run_id, key))
            } else function() {
              mirai::mirai(
                garry::.daemon_run_source(p2, b2, nd, cg, core, k2, out,
                                          open_options = oo),
                p2 = p2, b2 = b2, nd = nd, cg = cg, core = core, k2 = k2,
                oo = oo, out = chunk_file(sid, jj))
            })
          })
        }
      } else {
        # Coarse reads. RDS store: split into per-compute-chunk files on
        # write. Mori store: share the whole read buffer; consumers
        # slice their window zero-copy. Either way compute chunk j's
        # dependency is the READ task covering it.
        its <- chunk_iter(split_cg)
        dep_of <- character(nrow(its))
        elt_of <- sprintf("%s\x1f%d", skey, seq_len(nrow(its)))
        for (r in seq_len(nrow(it))) {
          members <- .exec_split_members(its, it[r, ])
          dep_of[members] <- sprintf("s%d_r%d", s@id, r)
          local({
            sid <- s@id; rr <- r; cg <- s@chunks; core <- it[rr, ]
            p2 <- rpath; b2 <- rband; nd <- rnodata; k2 <- skey; oo <- roo
            key <- sprintf("s%d_r%d", sid, rr)
            parts <- lapply(members, function(j) {
              list(r0 = its$y_off[[j]] - core$y_off,
                   c0 = its$x_off[[j]] - core$x_off,
                   nr = its$y_size[[j]], nc = its$x_size[[j]],
                   elt = elt_of[[j]],
                   file = chunk_file(sid, j))
            })
            add_task(key, character(0), if (use_shm) function() {
              mirai::mirai(
                garry::.daemon_run_source_shm(p2, b2, nd, cg, core, k2,
                                              reg, parts = parts,
                                              open_options = oo),
                p2 = p2, b2 = b2, nd = nd, cg = cg, core = core,
                k2 = k2, oo = oo, parts = parts,
                reg = sprintf("r%d_%s", run_id, key))
            } else function() {
              mirai::mirai(
                garry::.daemon_run_source_split(p2, b2, nd, cg, core, k2,
                                                parts, open_options = oo),
                p2 = p2, b2 = b2, nd = nd, cg = cg, core = core, k2 = k2,
                parts = parts, oo = oo)
            })
          })
        }
        source_deps[[.key(s@id)]] <- dep_of
        source_elts[[.key(s@id)]] <- elt_of
      }

    } else {  # compute / reduce_partial
      in_meta <- .exec_in_meta(graph, s, plan@stages)
      for (j in seq_len(nrow(it))) {
        local({
          sid <- s@id; jj <- j; fn <- s@fn; halo <- s@halo
          meta <- in_meta
          ck <- sprintf("r%d_s%d", run_id, sid)   # per-run jit cache key
          in_deps <- vapply(meta, function(m) {
            dep <- source_deps[[.key(m$id)]]
            if (is.null(dep)) sprintf("s%d_c%d", m$id, jj) else dep[[jj]]
          }, character(1))
          in_keys <- vapply(s@input_nodes, .key, character(1))
          # Mori store: coarse-read inputs address their part element.
          shm_keys <- vapply(seq_along(meta), function(i) {
            el <- source_elts[[.key(meta[[i]]$id)]]
            if (is.null(el)) in_keys[[i]] else el[[jj]]
          }, character(1))
          trims <- vapply(meta, function(m)
            as.integer(m$pad - halo), integer(1))
          dtypes <- vapply(meta, function(m) m$dtype, character(1))
          key <- sprintf("s%d_c%d", sid, jj)
          add_task(key, unique(in_deps), if (use_shm) function() {
            # Handles resolve at launch time: dependencies are done, so
            # `chunk_vals` holds every input's shared object (a ~30-byte
            # name over the wire).
            mirai::mirai(
              garry::.daemon_run_compute_shm(ck, fn, in_vals, in_keys,
                                             trims, dtypes, reg),
              ck = ck, fn = fn,
              in_vals = lapply(in_deps, function(d) chunk_vals[[d]]),
              in_keys = shm_keys,
              trims = trims, dtypes = dtypes,
              reg = sprintf("r%d_%s", run_id, key))
          } else function() {
            mirai::mirai(
              garry::.daemon_run_compute(ck, fn, in_files, in_keys,
                                          trims, dtypes, out),
              ck = ck, fn = fn,
              in_files = vapply(meta, function(m)
                chunk_file(m$id, jj), character(1)),
              in_keys = in_keys,
              trims = trims, dtypes = dtypes,
              out = chunk_file(sid, jj))
          })
          if (use_shm) {
            comp_stage_of[[key]] <- sid
            stage_left[[.key(sid)]] <-
              (stage_left[[.key(sid)]] %||% 0L) + 1L
            rk <- in_deps[grepl("_r\\d+$", in_deps)]
            stage_reads[[.key(sid)]] <-
              unique(c(stage_reads[[.key(sid)]], rk))
          }
        })
      }
    }
  }

  for (sk in ls(stage_reads))
    for (rk in stage_reads[[sk]])
      read_users[[rk]] <- (read_users[[rk]] %||% 0L) + 1L

  # Release read regions whose consuming stages have all completed.
  release_reads <- function(k) {
    sid <- comp_stage_of[[k]]
    if (is.null(sid)) return(invisible(NULL))
    sk <- .key(sid)
    stage_left[[sk]] <- stage_left[[sk]] - 1L
    if (stage_left[[sk]] > 0L) return(invisible(NULL))
    dead <- character(0)
    for (rk in stage_reads[[sk]]) {
      read_users[[rk]] <- read_users[[rk]] - 1L
      if (read_users[[rk]] == 0L) dead <- c(dead, rk)
    }
    if (length(dead) > 0L) {
      try(mirai::everywhere(garry::.daemon_shm_drop(regs),
                            regs = sprintf("r%d_%s", run_id, dead)),
          silent = TRUE)
      rm(list = intersect(dead, ls(chunk_vals)), envir = chunk_vals)
      gc(FALSE)   # host munmaps its handles; regions free once unlinked
    }
    invisible(NULL)
  }

  # Polling ready-queue with in-flight cap.
  inflight <- list()
  done <- character(0)
  is_ready <- function(t) all(t$deps %in% done)
  remaining <- function() {
    any(vapply(tasks, function(t) t$state != "done", logical(1)))
  }
  progress <- isTRUE(garry_opt("progress"))
  task_log <- garry_opt("task_log")
  log_line <- if (is.null(task_log)) function(...) NULL else {
    function(event, key) cat(sprintf("%.3f,%s,%s\n", unclass(Sys.time()),
                                     event, key),
                             file = task_log, append = TRUE)
  }
  n_total <- length(tasks)
  last_report <- Sys.time()
  while (remaining()) {
    for (k in names(tasks)) {
      if (length(inflight) >= cap) break
      t <- tasks[[k]]
      if (t$state == "pending" && is_ready(t)) {
        inflight[[k]] <- t$launch()
        tasks[[k]]$state <- "running"
        log_line("launch", k)
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
        if (use_shm) chunk_vals[[k]] <- h$data
        tasks[[k]]$state <- "done"
        done <- c(done, k)
        inflight[[k]] <- NULL
        harvested <- TRUE
        log_line("done", k)
        if (use_shm) release_reads(k)
      }
    }
    if (progress &&
        difftime(Sys.time(), last_report, units = "secs") > 5) {
      cat(sprintf("  garry: %d/%d tasks done, %d in flight\n",
                  length(done), n_total, length(inflight)))
      last_report <- Sys.time()
    }
    if (!harvested) Sys.sleep(0.002)
  }

  # Host-side: combines, then sink retrieval (mirrors execute_plan).
  # Sink/combine stages are never split-read sources (splits only exist
  # under a compute consumer), so chunk-keyed lookup always resolves.
  log_line("drain_end", "-")
  on.exit(log_line("host_end", "-"), add = TRUE)
  read_chunk <- function(sid, j) {
    if (use_shm) chunk_vals[[sprintf("s%d_c%d", sid, j)]]
    else readRDS(chunk_file(sid, j))
  }
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

  if (!is.null(path))
    return(.exec_write_sink(chunks, it, sink, path, nodata))

  if (nrow(it) == 1L) {
    v <- chunks[[1L]]
    if (is.matrix(v)) v <- .exec_trim(v, sink_pad)
    if (is.matrix(v) && all(dim(v) == c(1L, 1L))) return(v[1L, 1L])
    return(v)
  }
  .exec_assemble(chunks, it, sink@grid, sink_pad)
}
