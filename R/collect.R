#' @include passes.R
#' @keywords internal
NULL

#' Materialise a LazyRaster (or inspect its plan).
#'
#' Executes the plan and returns the result in the R session, always.
#' To stream the result to a file instead, use [write_tif()]; to
#' checkpoint to local cubes and stay lazy, use [materialise()].
#' `plan_only = TRUE` runs the planner passes and returns the `Plan`
#' without executing, for inspection.
#'
#' @param x A `LazyRaster`, a `LazyDataset` (its bands are assembled along
#'   the band axis via `stack_bands()` first), a named list of lazy rasters
#'   (multi-export: one plan, a named list of results), or a
#'   `LazyDatasetGroups` (one result per group).
#' @param plan_only Return the `Plan` instead of executing?
#' @param distributed Execute across the [garry_daemons()] pools? Defaults to
#'   [garry_daemons_set()], so `collect(x)` uses the pools when they are running
#'   and runs single-threaded otherwise. Pass `TRUE`/`FALSE` to override; the
#'   distributed result is identical to the single-threaded one.
#' @return With `plan_only = TRUE`, the `Plan`. Otherwise the materialised
#'   result in the R raster convention (spatial-first, layer-last): a scalar
#'   for global reductions, a `[y, x]` matrix for a single layer, or a
#'   `(y, x, band)` array for multiple bands
#'   (matching `terra::as.array()`; plots directly with `rasterImage`/`ximage`).
#'   A matrix/array result also carries a `gis` attribute in the style of
#'   `gdalraster::read_ds()` (`type`, `bbox` = `c(xmin, ymin, xmax, ymax)`,
#'   `dim` = `c(nx, ny, nbands)`, `srs` = WKT, `datatype`), so the array is
#'   self-describing and [preview()] can set real-world axes without the grid.
#' @examples
#' f <- system.file("extdata", "garry-example.tif", package = "garry")
#' red <- lazy_source(f, band = 1L)
#' nir <- lazy_source(f, band = 3L)
#' ndvi <- collect((nir - red) / (nir + red))
#' dim(ndvi)
#' @export
collect <- function(x, plan_only = FALSE, distributed = garry_daemons_set()) {
  .collect_impl(x, plan_only = plan_only, distributed = distributed)
}

# The execution engine behind collect()/write_tif()/materialise().
# `wspec` (write_tif) is the sink write spec: list(dtype, scale, offset),
# applied at the sink boundary by the executors.
.collect_impl <- function(
  x,
  plan_only = FALSE,
  path = NULL,
  nodata = NULL,
  distributed = garry_daemons_set(),
  band_names = NULL,
  wspec = NULL
) {
  .garry_opt_check()
  if (!rlang::is_bool(distributed)) {
    cli::cli_abort("{.arg distributed} must be {.code TRUE} or {.code FALSE}.")
  }
  if (!is.null(path)) {
    .check_write_path(x, path)
  }
  if (!plan_only) {
    .http_auth_sync()
  }
  # A grouped dataset materialises one result per time group (see
  # group_by_time()): a named list, or one file per group when `path` carries a
  # `{group}` placeholder.
  if (S7::S7_inherits(x, LazyDatasetGroups)) {
    return(.collect_groups(
      x,
      plan_only,
      path,
      nodata,
      distributed,
      wspec,
      band_names
    ))
  }
  # A dataset's band names become the output band descriptions; capture them
  # before stack_bands() collapses the named bands into one node.
  if (S7::S7_inherits(x, LazyDataset)) {
    band_names <- band_names %||% names(x@bands)
    x <- stack_bands(x)
  }
  p <- plan_lazy(x)
  if (plan_only) {
    return(p)
  }
  if (!is.null(path)) {
    .check_sink_nodata(p, nodata, wspec$dtype)
  }
  # Multi-export (design/multi-export-collect.md): several sinks share
  # one execution, on either executor.
  if (length(p@sinks) > 1L) {
    .garry_state$route <- if (distributed) "scheduler" else "single"
    res <- if (distributed) {
      execute_plan_mirai(
        p,
        path = path,
        nodata = nodata,
        band_names = band_names,
        wspec = wspec
      )
    } else {
      execute_plan(
        p,
        path = path,
        nodata = nodata,
        band_names = band_names,
        wspec = wspec
      )
    }
    if (!is.null(path)) {
      return(invisible(res))
    }
    # per-sink: same layout + gis attribute as a single-sink collect
    return(lapply(stats::setNames(seq_along(res), names(res)), function(k) {
      out <- .collect_layout(res[[k]])
      if (!is.null(dim(out))) {
        grid <- graph_get(p@graph, p@sinks[[k]])@grid
        nb <- if (length(dim(out)) == 3L) dim(out)[[3L]] else 1L
        bn <- if (is.list(band_names)) band_names[[names(res)[[k]]]] else NULL
        attr(out, "gis") <- .gis_attr(
          grid,
          nb,
          bn %||% .grid_layer_labels(grid)
        )
      }
      out
    }))
  }
  # Labelled output: a bare (t,y,x) / (band,y,x) result inherits its
  # axis labels (GridSpec labels, carried from lazy_stack layer names)
  # as output band descriptions unless the dataset already supplied
  # band names.
  band_names <- band_names %||% .grid_layer_labels(p@stages[[p@sink]]@grid)
  if (distributed && !garry_daemons_set()) {
    cli::cli_abort(c(
      "{.arg distributed} is TRUE but no garry daemon pools are running.",
      "i" = "Call {.fn garry_daemons} first, or pass {.code distributed = FALSE}."
    ))
  }
  # A plan that only reads (sources, warps of sources, or a stack of
  # them) has nothing to compute: read each layer straight into the
  # result array or output file, skipping the compute stage, chunk
  # assembly and layout permute. Same reads, same values.
  ro <- .read_only_spec(p, distributed)
  if (!is.null(ro)) {
    .garry_state$route <- "read_only"
    if (!is.null(path)) {
      return(invisible(
        .write_read_only(p, ro, path, nodata, band_names, wspec, distributed)
      ))
    }
    return(.collect_read_only(
      p,
      ro,
      distributed,
      gis = .gis_attr(p@stages[[p@sink]]@grid, ro$nk, band_names)
    ))
  }
  res <- if (distributed) {
    # Quantized writes (wspec with scale) bypass the cd/gd fast paths:
    # their band kernels do not yet fold g_quantize, and the one-
    # device-quantizer invariant (byte-identical digital numbers on
    # every route) is worth more than the fast path here. Folding wq
    # into the cd/gd kernels is the follow-up (ir-extensions-todo #12).
    quantizing <- !is.null(wspec) && length(wspec$scale) == 1L
    spec <- if (quantizing) NULL else .cd_spec(p) # composite fast path
    decomp <- if (is.null(spec) && !quantizing) .gd_decompose(p) else NULL
    # Record which route ran (garry_last_route()): the selection is
    # silent, and a plan silently changing route is exactly the
    # regression class the equivalence suite must be able to observe.
    .garry_state$route <- if (!is.null(spec)) {
      "composite_direct"
    } else if (!is.null(decomp)) {
      "gd_reduce"
    } else {
      "scheduler"
    }
    if (!is.null(spec)) {
      .execute_composite_direct(
        p,
        spec,
        path = path,
        nodata = nodata,
        band_names = band_names,
        wspec = wspec
      )
    } else if (!is.null(decomp)) {
      # Any reduce-structured graph (ndvi, nested reduce->map->reduce, focal over
      # a composite): overlap-compute the leaf reduces, run the upper IR on them.
      .execute_gd_reduce(
        p,
        decomp,
        path = path,
        nodata = nodata,
        band_names = band_names,
        wspec = wspec
      )
    } else {
      execute_plan_mirai(
        p,
        path = path,
        nodata = nodata,
        band_names = band_names,
        wspec = wspec
      )
    }
  } else {
    .garry_state$route <- "single"
    execute_plan(
      p,
      path = path,
      nodata = nodata,
      band_names = band_names,
      wspec = wspec
    )
  }
  if (!is.null(path)) {
    return(invisible(res))
  }
  out <- .collect_layout(res)
  # `out` can be `res` itself (a matrix passes through): drop the second
  # reference, or the attribute below duplicates the whole result
  rm(res)
  # Self-describing result: a gdalraster read_ds()-style `gis` attribute from the
  # plan's output grid. Only for rasters (matrix/array) -- a scalar global
  # reduction is not spatial. preview() reads it for real-world axes.
  if (!is.null(dim(out))) {
    grid <- p@stages[[p@sink]]@grid
    nb <- if (length(dim(out)) == 3L) dim(out)[[3L]] else 1L
    attr(out, "gis") <- .gis_attr(grid, nb, band_names)
  }
  out
}

#' Convert a collected result to a terra SpatRaster.
#'
#' `collect()` results carry a `gis` attribute (bbox, CRS, dims); this
#' wraps the array as a `terra::SpatRaster` for hand-off to the terra
#' ecosystem (plotting, zonal statistics, vector ops). Layers are named
#' after the dataset's bands, or a stack's labels, when the result has
#' them (`gis$band_names`).
#'
#' @param x A matrix or `(y, x, band)` array from [collect()] (must
#'   carry the `gis` attribute).
#' @return A `terra::SpatRaster`.
#' @export
as_terra <- function(x) {
  rlang::check_installed("terra", reason = "for as_terra().")
  gis <- attr(x, "gis")
  if (is.null(gis)) {
    cli::cli_abort(paste0(
      "{.arg x} has no {.code gis} attribute; pass an in-memory ",
      "{.fn collect} result (matrix or (y, x, band) array)"
    ))
  }
  a <- if (length(dim(x)) == 2L) array(x, c(dim(x), 1L)) else unclass(x)
  attr(a, "gis") <- NULL
  r <- terra::rast(
    a,
    crs = gis$srs,
    extent = terra::ext(
      gis$bbox[[1L]],
      gis$bbox[[3L]],
      gis$bbox[[2L]],
      gis$bbox[[4L]]
    )
  )
  nms <- dimnames(x)[[3L]] %||% gis$band_names
  if (!is.null(nms)) {
    names(r) <- nms
  }
  r
}

#' Which execution route did the last `collect()` take?
#'
#' A diagnostics helper. The distributed `collect()` picks its execution
#' route automatically, and this reports the route the last call took,
#' so pipelines can log it or assert a plan has not changed route.
#' The values are:
#'
#' - `"composite_direct"`: the specialised masked-composite executor;
#' - `"gd_reduce"`: the general reduce-decomposition executor;
#' - `"scheduler"`: the general distributed scheduler;
#' - `"single"`: the in-process single-threaded executor
#'   (`distributed = FALSE`);
#' - `"read_only"`: a plan that only reads and stacks rasters, copied
#'   from GDAL straight into the result in either mode.
#'
#' @return `"composite_direct"`, `"gd_reduce"`, `"scheduler"`, `"single"`
#'   or `"read_only"`; `NULL` before any `collect()` in the session.
#' @export
garry_last_route <- function() .garry_state$route

# Materialise each time group of a LazyDatasetGroups. With `path`, writes one
# file per group (a `{group}` placeholder is substituted, else the group label
# is inserted before the extension) and returns the paths invisibly; otherwise
# returns a named list of results (or Plans when `plan_only`).
.collect_groups <- function(
  x,
  plan_only,
  path,
  nodata,
  distributed,
  wspec = NULL,
  band_names = NULL
) {
  labels <- names(x@groups)
  paths <- if (is.null(path)) {
    NULL
  } else {
    stats::setNames(unlist(.group_paths(path, labels)), labels)
  }
  # a {group} placeholder may name a directory ("out/{group}/comp.tif")
  for (d in unique(dirname(as.character(paths)))) {
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
  }
  # Multi-export route (design/multi-export-collect.md): ONE plan whose
  # sinks are the per-group band stacks, so every group's reads enter
  # one ready queue and drain together under fetch-first priority.
  # The per-group loop pulsed the network instead: one fetch burst,
  # then an idle assemble/compute/write trough, per group
  # (ir-extensions-todo.md #5). plan_only keeps the loop: callers
  # expect one inspectable Plan per group.
  if (!plan_only && length(x@groups) > 1L) {
    sinks <- stats::setNames(lapply(x@groups, stack_bands), labels)
    bn <- stats::setNames(
      lapply(x@groups, function(g) band_names %||% names(g@bands)),
      labels
    )
    res <- .collect_impl(
      sinks,
      path = paths,
      nodata = nodata,
      distributed = distributed,
      band_names = bn,
      wspec = wspec
    )
    if (!is.null(path)) {
      return(invisible(paths))
    }
    return(res)
  }
  res <- lapply(seq_along(x@groups), function(i) {
    .collect_impl(
      x@groups[[i]],
      plan_only = plan_only,
      path = if (is.null(paths)) NULL else paths[[i]],
      nodata = nodata,
      distributed = distributed,
      band_names = band_names,
      wspec = wspec
    )
  })
  names(res) <- labels
  if (!is.null(path) && !plan_only) {
    return(invisible(paths))
  }
  res
}

# One output path per group: substitute a `{group}`/`{time}` placeholder, or
# insert the (filesystem-safe) group label before the file extension.
.group_paths <- function(path, labels) {
  safe <- gsub("[^A-Za-z0-9._-]", "-", labels)
  if (grepl("\\{group\\}|\\{time\\}", path)) {
    return(vapply(
      safe,
      function(s) gsub("\\{group\\}|\\{time\\}", s, path),
      character(1),
      USE.NAMES = FALSE
    ))
  }
  ext <- tools::file_ext(path)
  stem <- tools::file_path_sans_ext(path)
  vapply(
    safe,
    function(s) {
      if (nzchar(ext)) .glue("{stem}_{s}.{ext}") else .glue("{stem}_{s}")
    },
    character(1),
    USE.NAMES = FALSE
  )
}

# gdalraster read_ds()-style `gis` attribute from a GridSpec: type, bbox
# (xmin,ymin,xmax,ymax), dim (nx,ny,nbands), srs (WKT), datatype (GDAL name).
.gis_attr <- function(grid, nbands, band_names = NULL) {
  out <- list(
    type = "raster",
    bbox = as.numeric(grid@extent),
    dim = c(
      unname(grid@dims[["x"]]),
      unname(grid@dims[["y"]]),
      as.integer(nbands)
    ),
    srs = .canon_crs(grid@crs),
    datatype = unname(.gdal_dtype_rev[grid@dtype]) %|NA|% grid@dtype
  )
  if (length(band_names) == nbands && nbands > 1L) {
    out$band_names <- as.character(band_names)
  }
  out
}

# Normalise an in-memory collect() result to the R raster convention:
# spatial-first, layer-last. A scalar reduction stays a scalar; a 2D result
# stays a [y, x] matrix; a multiband/multitemporal result becomes (y, x, band)
# so it matches terra::as.array() and plots directly (rasterImage / ximage).
# Internals stay band-first ((band/t, y, x), decision D17); this permutes only
# at the user boundary. The composite path hands back a list of [y, x] matrices;
# the scheduler a (band, y, x) array.
.collect_layout <- function(res) {
  if (is.list(res)) {
    return(if (length(res) == 1L) res[[1L]] else simplify2array(res))
  }
  if (is.array(res) && length(dim(res)) == 3L) {
    return(aperm(res, c(2L, 3L, 1L)))
  }
  res
}

# The accepted write targets: one path for a raster, dataset or grouped
# dataset (a {group} placeholder or a directory expands per group), and
# for a named list of rasters either an existing directory or a path per
# sink named like the list.
.check_write_path <- function(x, path, call = rlang::caller_env()) {
  if (!is.character(path) || anyNA(path) || !all(nzchar(path))) {
    cli::cli_abort("{.arg path} must be a character vector of file paths.", call = call)
  }
  multi <- is.list(x) &&
    !S7::S7_inherits(x, LazyRaster) &&
    !S7::S7_inherits(x, LazyDataset) &&
    !S7::S7_inherits(x, LazyDatasetGroups)
  if (!multi) {
    if (length(path) != 1L) {
      cli::cli_abort("{.arg path} must be a single file path.", call = call)
    }
    return(invisible(path))
  }
  if (length(path) == 1L && is.null(names(path)) && dir.exists(path)) {
    return(invisible(path))
  }
  if (is.null(names(path)) || !setequal(names(path), names(x)) ||
      length(path) != length(x)) {
    cli::cli_abort(
      c(
        "{.arg path} for a list of rasters must be an existing directory or one path per sink, named like {.arg x}.",
        "i" = "Sinks: {.val {names(x)}}."
      ),
      call = call
    )
  }
  invisible(path)
}

# A written sentinel must be a value its bands hold. GDAL clamps or rounds
# any other when NaN is demoted to it, so a hole becomes valid data while
# the band declares a value no cell has. `dtype` is the write's override;
# without one each sink writes its own dtype. A predicate sink has no file
# dtype, and its write refuses it by name.
.check_sink_nodata <- function(p, nodata, dtype = NULL, call = rlang::caller_env()) {
  if (is.null(nodata)) {
    return(invisible(NULL))
  }
  if (!is.numeric(nodata) || length(nodata) != 1L || is.infinite(nodata) ||
      (is.na(nodata) && !is.nan(nodata))) {
    cli::cli_abort(
      "{.arg nodata} must be a single number (or NaN for a float output).",
      class = c("garry_write_error", "garry_error"),
      call = call
    )
  }
  dtypes <- dtype %||% if (length(p@sinks)) {
    unique(vapply(p@sinks, function(id) graph_get(p@graph, id)@grid@dtype, ""))
  } else {
    p@stages[[p@sink]]@grid@dtype
  }
  misfit <- Filter(function(dt) !.dtype_holds(dt, nodata), setdiff(dtypes, "pred"))
  if (length(misfit)) {
    dt <- misfit[[1L]]
    cli::cli_abort(c(
      "{.arg nodata} ({nodata}) does not fit output dtype {.val {dt}}.",
      "i" = if (.dtype_family(dt) != "float") {
        "An integer band holds whole numbers in its range, and no NaN."
      }
    ), class = c("garry_write_error", "garry_error"), call = call)
  }
  invisible(NULL)
}

# A read-only plan: NULL unless every layer of the sink is a source
# (single- or multi-band) or a warp of one at a dtype f32 holds exactly
# (the path moves values as f32, as the compute path does), read by its
# own source_read/warp stage with no halo, and (distributed) none the
# scheduler would fetch. Otherwise its read stages, the layers each
# contributes (`nb`) and the layer each starts at (`k0`).
.read_only_spec <- function(p, distributed = FALSE) {
  if (!isTRUE(garry_opt("read_only")) || length(p@sinks) > 1L) {
    return(NULL)
  }
  graph <- p@graph
  sink <- p@stages[[p@sink]]
  top <- graph_get(graph, sink@members[[length(sink@members)]])
  leaves <- if (S7::S7_inherits(top, StackNode)) top@parents else top@id
  read_stage <- lapply(leaves, function(id) {
    n <- graph_get(graph, id)
    multi <- (S7::S7_inherits(n, SourceNode) && length(n@band) > 1L) ||
      (S7::S7_inherits(n, WarpNode) && length(n@bands) > 1L)
    dims <- if (multi) c("x", "y", "band") else c("x", "y")
    if (!S7::S7_inherits(n, SourceNode) && !S7::S7_inherits(n, WarpNode)) {
      return(NULL)
    }
    if (!setequal(names(n@grid@dims), dims) ||
        !n@grid@dtype %in% .f32_exact_dtypes) {
      return(NULL)
    }
    for (s in p@stages) {
      if (s@kind %in% c("source_read", "warp") && identical(s@members[[1L]], id) &&
          s@halo == 0L && s@out_pad == 0L) {
        return(s)
      }
    }
    NULL
  })
  if (!length(read_stage) || any(vapply(read_stage, is.null, logical(1)))) {
    return(NULL)
  }
  # Remote mosaics the scheduler fetches (each item's window downloaded
  # to a local file in parallel, then read locally) beat chunk reads
  # straight from the remote, so they stay with the scheduler.
  if (distributed) {
    for (s in read_stage) {
      a <- .stage_read_args(graph, s)
      if (s@kind == "source_read" && .read_would_fetch(a$path, a$open_options)) {
        return(NULL)
      }
    }
  }
  g <- top@grid
  nb <- vapply(leaves, function(id) {
    d <- graph_get(graph, id)@grid@dims
    if ("band" %in% names(d)) as.integer(d[["band"]]) else 1L
  }, integer(1))
  nk <- sum(nb)
  if (length(g@dims) > 3L || nk != prod(g@dims[setdiff(names(g@dims), c("x", "y"))])) {
    return(NULL)
  }
  list(
    read_stage = read_stage,
    nb = nb,
    k0 = cumsum(c(0L, nb))[seq_along(nb)],
    nk = nk,
    ny = g@dims[["y"]],
    nx = g@dims[["x"]]
  )
}

# Read every chunk of a read-only plan as raw f32 (the executor's own
# read) and hand each to emit(v, y_off, x_off, k): `v` holds the
# (nb[k], h, w) or (h, w) planes of leaf k. In-process, local files
# decode on every core; distributed, the read pool reads the chunks
# and the host only copies them into place, in completion order.
.read_only_each <- function(p, spec, emit, distributed = FALSE, ...) {
  graph <- p@graph
  ra <- lapply(spec$read_stage, function(s) .stage_read_args(graph, s))
  if (distributed) {
    return(.read_only_each_pool(spec, ra, emit, ...))
  }
  restore_threads <- .gdal_threads_all(unique(unlist(lapply(ra, `[[`, "path"))))
  on.exit(restore_threads(), add = TRUE)
  for (k in seq_along(spec$read_stage)) {
    s <- spec$read_stage[[k]]
    a <- ra[[k]]
    it <- chunk_iter(s@chunks)
    for (j in seq_len(nrow(it))) {
      v <- .exec_read_padded(a, s@chunks, it[j, ], out = "raw_f32")
      emit(v, it$y_off[[j]], it$x_off[[j]], k)
    }
  }
  invisible(NULL)
}

# The distributed read loop: one read task per chunk on the read pool,
# at most two a daemon in flight (so finished chunks never pile up on
# the host), each emitted as it lands.
.read_only_each_pool <- function(
  spec,
  ra,
  emit,
  backlog = function(n) 0L,
  poll = function() FALSE,
  task = NULL,
  cap = NULL,
  tl = NULL,
  watch = NULL
) {
  prof <- "garry_read"
  .assert_pools_alive(prof)
  .garry_abi_check(prof)
  .daemons_run_start(prof)
  todo <- do.call(rbind, lapply(seq_along(spec$read_stage), function(k) {
    data.frame(k = k, j = seq_len(nrow(chunk_iter(spec$read_stage[[k]]@chunks))))
  }))
  its <- lapply(spec$read_stage, function(s) chunk_iter(s@chunks))
  cap <- cap %||% max(.daemon_depth * .gd_n_compute(prof), .daemon_depth)
  # The scheduler's task-log rows, read tasks keyed as its chunk reads
  # are: each read is ready at the start, and the daemon's own start and
  # end times separate its run time from its wait behind the daemon's
  # last read. A caller with a tail of its own opens the log and logs
  # `host_end` itself.
  if (is.null(tl)) {
    tl <- .task_log_open(.garry_run_id(), c(read = .gd_n_compute(prof)))
    on.exit(tl$line("host_end", "-"), add = TRUE)
  }
  log_line <- tl$line
  timed <- tl$timed
  t_ready <- formatC(unclass(Sys.time()), format = "f", digits = 3)
  key_of <- function(i) {
    .glue("s{spec$read_stage[[todo$k[[i]]]]@id}_c{todo$j[[i]]}")
  }
  inflight <- list()
  next_i <- 1L
  # a dead daemon's task never resolves: `watch` adds the pools a caller's
  # own tasks wait on, whose backlog can stop these reads
  idle <- .idle_step(c(prof, watch))
  launch <- function(i) {
    k <- todo$k[[i]]
    a <- ra[[k]]
    core <- its[[k]][todo$j[[i]], ]
    if (timed) {
      log_line(
        "launch",
        key_of(i),
        pool = "read",
        slot = "read",
        mb = round(core$x_size * core$y_size * spec$nb[[k]] * 4 / 2^20, 1),
        ready = t_ready
      )
    }
    if (!is.null(task)) {
      return(task(i, a, spec$read_stage[[k]]@chunks, core, timed))
    }
    .task_mirai(
      quote(asNamespace("garry")$.exec_read_padded(a, cg, core, out = "raw_f32")),
      a = a,
      cg = spec$read_stage[[k]]@chunks,
      core = core,
      .compute = prof,
      .timed = timed
    )
  }
  while (next_i <= nrow(todo) || length(inflight)) {
    # `backlog()` (queued writes) shares the cap: chunks waiting to be
    # written hold host memory just as reads in flight do
    while (
      next_i <= nrow(todo) &&
        length(inflight) + backlog(length(inflight)) < cap
    ) {
      inflight[[as.character(next_i)]] <- launch(next_i)
      next_i <- next_i + 1L
    }
    harvested <- poll()
    for (key in names(inflight)) {
      h <- inflight[[key]]
      if (mirai::unresolved(h)) {
        next
      }
      inflight[[key]] <- NULL
      harvested <- TRUE
      if (inherits(h$data, "errorValue")) {
        .task_abort("read task failed on daemon", h$data)
      }
      i <- as.integer(key)
      k <- todo$k[[i]]
      core <- its[[k]][todo$j[[i]], ]
      emit(.task_landed(log_line, key_of(i), h$data), core$y_off, core$x_off, k)
    }
    tl$tick() # the readers pin shared regions
    if (!harvested) {
      idle()
    }
  }
  log_line("drain_end", "-")
  invisible(NULL)
}

# The read-only collect: the (y, x) matrix or (y, x, layer) array, each
# chunk copied into place in one pass.
.collect_read_only <- function(p, spec, distributed = FALSE, gis = NULL) {
  ny <- spec$ny
  nx <- spec$nx
  nk <- spec$nk
  # every cell is written below (the chunks tile the grid), so the
  # result is allocated without the NA fill
  out <- .Call("garry_alloc_double", as.numeric(ny) * nx * nk, PACKAGE = "garry")
  dim(out) <- if (nk == 1L) c(ny, nx) else c(ny, nx, nk)
  .read_only_each(p, spec, function(v, y_off, x_off, k) {
    d <- attr(v, "gdim")
    .Call(
      "garry_f32_into_colmajor",
      out,
      v,
      as.numeric(c(y_off, x_off, spec$k0[[k]])),
      as.numeric(c(ny, nx, nk, spec$nb[[k]], d[[length(d) - 1L]], d[[length(d)]])),
      PACKAGE = "garry"
    )
  }, distributed = distributed)
  # set here, while `out` has one reference: an attribute set on the
  # caller's copy duplicates the whole array
  attr(out, "gis") <- gis
  out
}

# The read-only write: each chunk goes from the read straight to its
# bands of the output, through the sink write's quantizer. With pools,
# the writer daemon writes as the read pool reads, so compression never
# stalls the host's read loop, and a dead writer fails the write;
# quantized writes stay on the host, where the device quantizer is.
.write_read_only <- function(p, spec, path, nodata, band_names, wspec, distributed = FALSE) {
  sink <- p@stages[[p@sink]]
  nodata <- as.numeric(nodata)
  ds <- .sink_output(path, sink@grid, nodata, band_names, wspec)
  wdt <- wspec$dtype %||% sink@grid@dtype
  wq <- .exec_wq(wspec, nodata)
  if (distributed && is.null(wq)) {
    gdal_close_output(ds, path)
    .write_read_only_pool(p, spec, path, nodata, wdt)
    return(invisible(path))
  }
  on.exit(try(ds$close(), silent = TRUE), add = TRUE)
  .read_only_each(p, spec, function(v, y_off, x_off, k) {
    v <- .exec_quantize_value(v, wq)
    for (b in seq_len(spec$nb[[k]])) {
      gdal_write_window(
        ds,
        x_off,
        y_off,
        v,
        dtype = wdt,
        nodata = nodata,
        band = spec$k0[[k]] + b,
        plane = b
      )
    }
  }, distributed = distributed)
  gdal_close_output(ds, path)
}

# Stream a read-only plan to the writer daemon. Each read task also
# prepares its chunk's band writes and shares them (shared memory,
# pinned on the reader); the host hands the region NAME to the writer
# and, once written, has the read pool drop it. Payloads never pass
# through the host, and the writer only writes, overlapping the reads.
.write_read_only_pool <- function(p, spec, path, nodata, dtype) {
  prof <- "garry_write"
  .assert_pools_alive(prof)
  .garry_abi_check(prof)
  run <- .garry_run_id()
  writes <- list()
  pending <- character(0) # written regions not yet dropped
  pending_mb <- 0
  live_mb <- 0 # shared memory pinned on the readers
  done <- FALSE
  # Writes log as tasks of their own pool (keys w<leaf>_c<n>), so a log
  # shows whether the readers or the writer set the pace.
  n_read <- .gd_n_compute("garry_read")
  tl <- .task_log_open(run, c(read = n_read, write = 1L))
  n_write <- 0L
  # the write tail is this run's host tail, logged however the run ends
  on.exit(tl$line("host_end", "-"), add = TRUE)
  # A drop is a broadcast to every reader, which waits for each one's
  # current read: drop in large batches (a quarter of the read budget),
  # not per write. The rest go at the end.
  drop <- function(regs) {
    if (length(regs)) {
      mirai::everywhere(
        asNamespace("garry")$.daemon_shm_drop(regs),
        regs = regs,
        .compute = "garry_read"
      )
    }
  }
  # Whatever happens, wait out the writes, close the writer's handles
  # and drop this run's regions; on success the close is checked below.
  on.exit(
    {
      if (!done) {
        .writer_settle(writes)
      }
      try(drop(c(pending, vapply(writes, `[[`, character(1), "reg"))), silent = TRUE)
    },
    add = TRUE
  )
  harvest <- function() {
    any <- FALSE
    for (key in names(writes)) {
      w <- writes[[key]]
      if (mirai::unresolved(w$h)) {
        next
      }
      if (inherits(w$h$data, "errorValue")) {
        .task_abort("write failed on the writer daemon", w$h$data, "garry_write_error")
      }
      .task_landed(tl$line, w$key, w$h$data)
      writes[[key]] <<- NULL
      pending <<- c(pending, w$reg)
      pending_mb <<- pending_mb + w$mb
      any <- TRUE
    }
    if (pending_mb >= 0.25 * budget_mb) {
      flush()
    }
    if (difftime(Sys.time(), budget_t, units = "secs") >= 5) {
      refresh_budget()
    }
    any
  }
  flush <- function() {
    drop(pending)
    live_mb <<- live_mb - pending_mb
    pending <<- character(0)
    pending_mb <<- 0
  }
  # The read budget, as the scheduler's: inside what RAM, /dev/shm and
  # the cgroup allow now, on the same clock, and never below a region
  # (planes are doubles, 8 B a cell).
  budget_cfg <- garry_opt("read_budget_mb")
  budget_mb <- budget_cfg
  region_mb <- max(vapply(
    seq_along(spec$read_stage),
    function(k) {
      s <- spec$read_stage[[k]]
      .store_region_mb(s@chunks@chunk_dim, s@grid@dims, 0L, spec$nb[[k]], 8)
    },
    numeric(1)
  ))
  refresh_budget <- function() {
    b <- .store_budget(budget_cfg, region_mb, live_mb, garry_opt("exec_ram_fraction"))
    budget_t <<- Sys.time()
    if (is.null(b)) {
      return(invisible(NULL))
    }
    budget_mb <<- b$read
    if (b$tight) {
      flush()
    }
  }
  budget_t <- Sys.time()
  refresh_budget()
  # Reads in flight: two a reader, each priced from launch as the
  # scheduler prices its reads, so a tight budget binds before they land.
  # The first read always goes, or a store that fills would stop its own
  # drain.
  cap <- max(2L * n_read, 2L)
  .read_only_each(
    p,
    spec,
    function(w, y_off, x_off, k) {
      live_mb <<- live_mb + w$mb
      n_write <<- n_write + 1L
      key <- paste0("w", spec$read_stage[[k]]@id, "_c", n_write)
      writes[[w$reg]] <<- list(
        reg = w$reg,
        mb = w$mb,
        key = key,
        h = .task_launch(
          tl,
          key,
          quote(asNamespace("garry")$.daemon_write_shared(path, xo, yo, w, b0)),
          path = path,
          xo = x_off,
          yo = y_off,
          w = w,
          b0 = spec$k0[[k]],
          .compute = prof,
          .pool = "write",
          .mb = w$mb
        )
      )
    },
    distributed = TRUE,
    backlog = function(n) {
      if (n > 0L && live_mb + (n + 1L) * region_mb > budget_mb) cap else length(writes)
    },
    poll = harvest,
    cap = cap,
    tl = tl,
    watch = prof,
    task = function(i, a, cg, core, timed) {
      .task_mirai(
        quote(asNamespace("garry")$.daemon_read_for_write(
          a,
          cg,
          core,
          dt,
          nd,
          reg
        )),
        a = a,
        cg = cg,
        core = core,
        dt = dtype,
        nd = nodata,
        reg = .glue("ro{run}_{i}"),
        .compute = "garry_read",
        .timed = timed
      )
    }
  )
  idle <- .idle_step(prof)
  while (length(writes)) {
    if (!harvest()) {
      idle()
    }
  }
  done <- TRUE
  .writer_close()
  invisible(path)
}
