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
#'   and runs in this R process otherwise. Pass `TRUE`/`FALSE` to override. One
#'   plan gives the same cells either way; a reprojected STAC band warps by a
#'   different route on each, so its cells can differ within GDAL's tolerance.
#' @return With `plan_only = TRUE`, the `Plan`. Otherwise the materialised
#'   result in the R raster convention (spatial-first, layer-last): a scalar
#'   for global reductions, a `[y, x]` matrix for a single layer, or a
#'   `(y, x, band)` array for multiple bands
#'   (matching `terra::as.array()`; plots directly with `rasterImage`/`ximage`).
#'   A matrix/array result also carries a `gis` attribute in the style of
#'   `gdalraster::read_ds()` (`type`, `bbox` = `c(xmin, ymin, xmax, ymax)`,
#'   `dim` = `c(nx, ny, nbands)`, `srs` = WKT, `datatype`), so the array is
#'   self-describing and [preview()] can set real-world axes without the grid.
#'   An `i32` cell of -2^31 reads as `NA`, the value R's integers keep for it.
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

# The way into execution for collect()/write_tif()/materialise(). A run with
# a `path` writes, through .collect_write().
# `wspec` (write_tif) is the sink write spec: list(dtype, scale, offset),
# applied at the sink boundary by the executors.
.collect_impl <- function(
  x,
  plan_only = FALSE,
  path = NULL,
  nodata = NULL,
  distributed = garry_daemons_set(),
  band_names = NULL,
  wspec = NULL,
  finish = NULL
) {
  .garry_opt_check()
  if (!rlang::is_bool(distributed)) {
    cli::cli_abort("{.arg distributed} must be {.code TRUE} or {.code FALSE}.")
  }
  if (is.null(path)) {
    return(.collect_run(x, plan_only, path, nodata, distributed, band_names, wspec))
  }
  .collect_write(x, path, nodata, distributed, band_names, wspec, finish)
}

# A run with a path writes its result through .write_through().
.collect_write <- function(x, path, nodata, distributed, band_names, wspec, finish) {
  .check_write_path(x, path)
  targets <- .write_targets(x, path)
  .write_through(targets, function(work) {
    .collect_run(x, FALSE, work, nodata, distributed, band_names, wspec)
    if (!is.null(finish)) {
      finish(work, targets)
    }
  })
  invisible(targets)
}

# The one rule of every write: `run(work)` builds `targets` at temporary paths
# in hidden directories beside them, and they move into place only if it
# returns. So a plan may read its own target and gets the old values, and a
# failed run leaves every target as it was, whatever route it took and however
# far it got.
.write_through <- function(targets, run, call = rlang::caller_env()) {
  stage <- .write_stage(targets, call)
  on.exit(unlink(stage$dirs, recursive = TRUE, expand = FALSE), add = TRUE)
  tryCatch(
    {
      for (d in unique(dirname(stage$work))) {
        why <- tryCatch(dir.create(d, recursive = TRUE), warning = .file_reason)
        if (!dir.exists(d)) {
          cli::cli_abort(
            c("cannot create a temporary directory for {.path {d}}.", "x" = "{why}"),
            class = c("garry_write_error", "garry_error"),
            call = call
          )
        }
      }
      run(stage$work)
      .write_publish(stage, targets, call)
    },
    error = function(e) stop(.write_named(e, stage))
  )
}

# The files a write of `x` to `path` produces, in the shape the routes take:
# one path, one named by sink, or one named by group.
.write_targets <- function(x, path) {
  if (S7::S7_inherits(x, LazyDatasetGroups)) {
    stats::setNames(.group_paths(path, names(x@groups)), names(x@groups))
  } else if (.is_sink_list(x)) {
    .sink_paths(path, names(x))
  } else {
    path
  }
}

# Where each target builds, with nothing yet created: `work` matches `targets`,
# and `dirs` holds the temporary directories, named by the directory each sits
# in. That is the target's nearest existing one, so a rename stays on one
# filesystem. Below it a file keeps its own name, which keeps a .vrt's reference
# to its .bin, and any directories the target still lacks, so a failed run
# creates none. Absolute, as a daemon resolves a relative path in its own
# working directory. A /vsi target is on no directory here, so it builds in the
# session's and is copied (gdal_place()). What can never be a target is refused
# here, before the run.
.write_stage <- function(targets, call = rlang::caller_env()) {
  refuse <- function(message) {
    cli::cli_abort(message, class = c("garry_write_error", "garry_error"), call = call)
  }
  url <- .url_scrub(targets[grepl("^[A-Za-z][A-Za-z0-9+.-]+://", targets)])
  if (length(url)) {
    refuse(c(
      "cannot write to the URL {.path {url[[1L]]}}.",
      "i" = "GDAL writes to a store through its /vsi path, such as {.path /vsis3/bucket/key.tif}."
    ))
  }
  taken <- targets[dir.exists(targets)]
  if (length(taken)) {
    refuse("cannot write a raster over the directory {.path {taken[[1L]]}}.")
  }
  work <- targets
  dirs <- character()
  on_vsi <- .gdal_is_vsi(targets)
  for (i in seq_along(targets)) {
    rel <- basename(targets[[i]])
    home <- dirname(targets[[i]])
    vsi <- on_vsi[[i]]
    while (!vsi && !dir.exists(home)) {
      # a file on the way is no directory to create, and neither is a `.` or
      # `..` below a missing directory, or a root that is not there
      if (file.exists(home) || basename(home) %in% c(".", "..") || dirname(home) == home) {
        refuse("cannot write {.path {targets[[i]]}}: {.path {home}} is not a directory.")
      }
      rel <- file.path(basename(home), rel)
      home <- dirname(home)
    }
    if (!vsi) {
      home <- normalizePath(home, winslash = "/")
    }
    if (is.na(dirs[home])) {
      # tempfile() joins with a backslash on Windows, which dirname() later turns
      # to a slash, and .write_named() must find the same string in a message
      at <- if (vsi) tempdir() else home
      dirs[[home]] <- file.path(at, basename(tempfile(".garry-write-", tmpdir = at)))
    }
    work[[i]] <- file.path(dirs[[home]], rel)
  }
  twice <- work %in% work[duplicated(work)]
  if (any(twice)) {
    refuse(c(
      "{.val {names(targets)[twice]}} would write the same file, {.path {targets[twice][[1L]]}}.",
      "i" = "Give each its own path."
    ))
  }
  list(work = work, dirs = dirs)
}

# Which of `work` each built file goes with: itself, or the one it extends by
# name (x.bin and x.tif.aux.xml go with x.tif). NA for neither.
.write_owner <- function(files, work) {
  keys <- c(work, tools::file_path_sans_ext(work))
  owner <- rep(NA_integer_, length(files))
  name <- files
  repeat {
    left <- is.na(owner)
    owner[left] <- (match(name[left], keys) - 1L) %% length(work) + 1L
    shorter <- tools::file_path_sans_ext(name)
    if (!anyNA(owner) || identical(shorter, name)) {
      return(owner)
    }
    name <- shorter
  }
}

# Close whatever could serve a replaced target's old pixels, here and on the
# daemons. Before the moves, so no process holds a target at its rename. A new
# file has no reader to mislead, so a write replacing nothing sends nothing.
.write_release <- function(targets) {
  if (!any(gdal_exists(targets))) {
    return(invisible(NULL))
  }
  .gdal_handles_release(targets)
  .pool_broadcast(
    quote(asNamespace("garry")$.gdal_handles_release(targets)),
    profiles = c("garry_read", .comp_profiles()),
    targets = unname(targets),
    live_only = TRUE,
    what = "closing the daemons' read handles"
  )
}

# Move everything a run built into place, target by target. What a target
# produced beside it (a .bin, an .aux.xml) goes first, so a .vrt never points at
# nothing; a sidecar left by the file it replaced goes after it, as GDAL's own
# create takes it. A failed move stops here and says what it left, and the
# run's unmoved files go with its temporary directories. An interrupt waits for
# the last move, so it cannot leave a partial result unreported.
.write_publish <- function(stage, targets, call = rlang::caller_env()) {
  work <- stage$work
  rel <- lapply(stage$dirs, list.files, recursive = TRUE, all.files = TRUE)
  from <- unlist(Map(file.path, stage$dirs, rel), use.names = FALSE)
  to <- unlist(Map(file.path, names(stage$dirs), rel), use.names = FALSE)
  lost <- targets[!work %in% from]
  if (length(lost)) {
    cli::cli_abort(
      "the run finished without building {.path {lost}}.",
      class = c("garry_write_error", "garry_error"),
      call = call
    )
  }
  owner <- .write_owner(from, work)
  built <- from %in% work
  turn <- order(owner, built)
  from <- from[turn]
  to <- to[turn]
  owner <- owner[turn]
  built <- built[turn]
  stale <- outer(to, .gdal_sidecars, paste0)
  stale[stale %in% to] <- NA
  .write_release(targets)
  suspendInterrupts(
    for (i in seq_along(from)) {
      why <- gdal_place(from[[i]], to[[i]])
      if (!is.null(why)) {
        moved <- tabulate(owner[seq_len(i - 1L)], length(targets))
        whole <- moved == tabulate(owner, length(targets))
        cli::cli_abort(
          c(
            "the run succeeded, but {.path {to[[i]]}} could not move into place.",
            "x" = "{why}",
            "i" = if (any(whole)) "Already in place: {.path {targets[whole]}}.",
            "!" = if (any(moved > 0L & !whole)) {
              "Old and new files mixed, so write these again: {.path {targets[moved > 0L & !whole]}}."
            },
            "i" = if (any(moved == 0L)) "Still as they were: {.path {targets[moved == 0L]}}."
          ),
          class = c("garry_write_error", "garry_error"),
          call = call
        )
      }
      if (built[[i]]) {
        gdal_remove(stale[i, !is.na(stale[i, ])])
      }
    }
  )
  invisible(NULL)
}

# A failure names where the file was going: the temporary paths in it are gone
# by the time anyone reads them.
.write_named <- function(e, stage) {
  for (f in intersect(names(e), c("message", "body"))) {
    if (is.character(e[[f]])) {
      for (home in names(stage$dirs)) {
        e[[f]][] <- gsub(stage$dirs[[home]], home, e[[f]], fixed = TRUE)
      }
    }
  }
  e
}

# The files at a target path: a raw cube's .bin sits beside its .vrt.
.target_files <- function(path) {
  unique(c(path, sub("\\.vrt$", ".bin", path, ignore.case = TRUE)))
}

# Execute `x`: in memory, or to the temporary `path` of .collect_write().
.collect_run <- function(x, plan_only, path, nodata, distributed, band_names, wspec) {
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
#' A diagnostics helper. garry picks the execution route automatically, and
#' this reports the route the last [collect()], [write_tif()] or
#' [materialise()] took,
#' so pipelines can log it or assert a plan has not changed route.
#' The values are:
#'
#' - `"composite_direct"`: the specialised masked-composite executor;
#' - `"gd_reduce"`: the general reduce-decomposition executor;
#' - `"scheduler"`: the general distributed scheduler;
#' - `"single"`: the in-process executor
#'   (`distributed = FALSE`);
#' - `"read_only"`: a plan that only reads and stacks rasters, copied
#'   from GDAL straight into the result in either mode.
#'
#' @return `"composite_direct"`, `"gd_reduce"`, `"scheduler"`, `"single"`
#'   or `"read_only"`; `NULL` before any `collect()` in the session.
#' @export
garry_last_route <- function() .garry_state$route

# Materialise each time group of a LazyDatasetGroups: a named list of results
# (or Plans when `plan_only`), or with `path`, one file per group
# (.write_targets()).
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
    return(.collect_run(
      sinks,
      plan_only = FALSE,
      path = path,
      nodata = nodata,
      distributed = distributed,
      band_names = bn,
      wspec = wspec
    ))
  }
  res <- lapply(seq_along(x@groups), function(i) {
    .collect_run(
      x@groups[[i]],
      plan_only = plan_only,
      path = if (is.null(path)) NULL else path[[i]],
      nodata = nodata,
      distributed = distributed,
      band_names = band_names,
      wspec = wspec
    )
  })
  names(res) <- labels
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

# A named list of rasters: one sink, and one file, per element.
.is_sink_list <- function(x) {
  is.list(x) &&
    !S7::S7_inherits(x, LazyRaster) &&
    !S7::S7_inherits(x, LazyDataset) &&
    !S7::S7_inherits(x, LazyDatasetGroups)
}

# The accepted write targets: one path for a raster, dataset or grouped
# dataset (a {group} placeholder, or the label before the extension, expands
# it per group), and for a named list of rasters either an existing directory
# or a path per sink named like the list. .write_stage() refuses what no path
# can name.
.check_write_path <- function(x, path, call = rlang::caller_env()) {
  if (!is.character(path) || anyNA(path) || !all(nzchar(path))) {
    cli::cli_abort("{.arg path} must be a character vector of file paths.", call = call)
  }
  if (!.is_sink_list(x)) {
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
      if (s@kind != "source_read") {
        next
      }
      a <- .stage_read_args(graph, s)
      if (.read_would_fetch(a$path, a$open_options)) {
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
    read_stage = Map(.read_only_chunks, read_stage, nb, MoreArgs = list(graph = graph)),
    nb = nb,
    k0 = cumsum(c(0L, nb))[seq_along(nb)],
    nk = nk,
    ny = g@dims[["y"]],
    nx = g@dims[["x"]]
  )
}

# The stage with a single-band file's chunks grown to one read task's
# worth. The plan cut a stack as a kernel's inputs, a window of every
# layer held at once, and no kernel holds them here. Cut that finely,
# chunks fetch the source tiles they share again: 144 warped files in nine
# chunks each took 2.7x the bytes, and a task to a file is the fastest
# split in region. Chunks of an unwarped file end on its tiles; a warp's
# target pixels have no tiles to end on. Anything else keeps its planned
# chunks, which are priced for it: the bands of a chunk, the parts of a
# mosaic, a Zarr's chunks, decoded and coarsened reads.
.read_only_chunks <- function(s, nb, graph) {
  cg <- s@chunks
  target <- garry_opt("read_target_px")
  node <- graph_get(graph, s@members[[1L]])
  warp <- s@kind == "warp"
  src <- if (warp) graph_get(graph, node@parents[[1L]]) else node
  dims <- as.numeric(cg@grid@dims[c("x", "y")])
  if (
    nb > 1L ||
      prod(pmin(cg@chunk_dim, dims)) >= target ||
      length(src@path) > 1L ||
      length(src@decode) > 0L ||
      .gdal_is_zarr(src@path) ||
      (warp && node@coarsen > 1L)
  ) {
    return(s)
  }
  block <- if (warp) c(1, 1) else as.numeric(cg@block_dim)
  fit <- function(want, ax) {
    min(dims[[ax]], max(block[[ax]], floor(want / block[[ax]]) * block[[ax]]))
  }
  if (prod(dims) <= target) {
    want <- dims
  } else {
    cy <- fit(target / fit(sqrt(target), 1L), 2L)
    want <- c(fit(target / cy, 1L), cy)
  }
  s@chunks@chunk_dim <- as.integer(want)
  s
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
# the host), each emitted as it lands. A failed loop cancels the reads
# it leaves queued: the read pool drops them, and a running one ends
# first (.task_cancel()).
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
  on.exit(.task_cancel(inflight), add = TRUE)
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
    .task_submit(
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
      if (.task_unresolved(h)) {
        next
      }
      inflight[[key]] <- NULL
      harvested <- TRUE
      if (inherits(h$data, "garry_task_failure")) {
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

# May a pool write take another read, with `n` reads in flight and
# `queued` writes waiting? Inside the budget, or when nothing is running:
# a store that fills must still drain, and queued writes drain it.
.read_fits <- function(n, queued, live_mb, region_mb, budget_mb) {
  (n == 0L && queued == 0L) || live_mb + (n + 1L) * region_mb <= budget_mb
}

# The read-only write: each chunk goes from the read straight to its
# bands of the output, through the sink write's quantizer. With pools,
# the writer daemon writes as the read pool reads, so compression never
# stalls the host's read loop, and a dead writer fails the write;
# quantized writes stay on the host, where the device quantizer is.
.write_read_only <- function(p, spec, path, nodata, band_names, wspec, distributed = FALSE) {
  sink <- p@stages[[p@sink]]
  nodata <- as.numeric(nodata)
  wdt <- wspec$dtype %||% sink@grid@dtype
  wq <- .exec_wq(wspec, nodata)
  a <- if (is.null(wq)) .copy_args(p, spec, path, nodata, wdt, wspec)
  if (!is.null(a)) {
    return(gdal_copy_gtiff(a$path, path, a$band, nodata, wspec$options, band_names))
  }
  ds <- .sink_output(path, sink@grid, nodata, band_names, wspec)
  if (distributed && is.null(wq)) {
    gdal_close_output(ds, path)
    store <- .store_broadcasts("garry_read")
    .run_guard(.write_read_only_pool(p, spec, path, nodata, wdt, store), store)
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

# The read args of a plan that is one local file written out whole, cells and
# type as they are, or NULL. GDAL then does the whole write: a 1 GB 64-band file
# took 1.8 s at a 450 MB peak, against 4.7 s and 7 GB moving each band through R
# and /dev/shm. A source that reads from the network, a local VRT of remote tiles
# among them, stays with the read pool: it retries a failed read, where this one
# translate does not, and a threaded GDAL read that fails on a worker thread aborts
# the host (.gdal_threads_all()).
.copy_args <- function(p, spec, path, nodata, dtype, wspec) {
  s <- spec$read_stage[[1L]]
  if (
    length(spec$read_stage) != 1L || s@kind != "source_read" ||
      grepl("\\.vrt$", path, ignore.case = TRUE) ||
      length(wspec$scale) || length(wspec$offset)
  ) {
    return(NULL)
  }
  a <- .stage_read_args(p@graph, s)
  if (
    length(a$path) != 1L || !file.exists(a$path) || length(a$open_options) ||
      !is.null(a$decim) || length(a$scale) || length(a$offset)
  ) {
    return(NULL)
  }
  ds <- .gdal_probe(a$path)
  # The read path turns a source's nodata, the file's own sentinel, which any
  # read masks whatever the node says, and a float's NaN into `nodata`.
  own <- vapply(a$band, function(b) ds$getNoDataValue(b), 0)
  sentinels <- unique(as.numeric(c(a$nodata, own[!is.na(own)])))
  nan <- function(v) !length(v) || all(is.nan(v))
  same_cells <- if (.dtype_family(dtype) == "float") {
    nan(sentinels) && nan(nodata)
  } else {
    !length(sentinels) || identical(sentinels, nodata)
  }
  if (!same_cells) {
    return(NULL)
  }
  g <- p@stages[[p@sink]]@grid
  same <- ds$getRasterXSize() == g@dims[["x"]] && ds$getRasterYSize() == g@dims[["y"]] &&
    isTRUE(all.equal(ds$getGeoTransform(), g@transform)) &&
    crs_equal(ds$getProjection(), g@crs) &&
    all(vapply(a$band, function(b) .gdal_band_dtype(ds, b), "") == dtype)
  if (same && !.gdal_reads_remote(a$path)) a
}

# Stream a read-only plan to the writer daemon. Each read task also
# prepares its chunk's band writes and shares them (shared memory,
# pinned on the reader); the host hands the region NAME to the writer
# and, once written, has the read pool drop it. Payloads never pass
# through the host, and the writer only writes, overlapping the reads.
# `store` (.store_broadcasts()) drops and clears the readers' regions.
.write_read_only_pool <- function(p, spec, path, nodata, dtype, store) {
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
  # not per write. The run's closing clear frees the rest, and the run
  # waits for every drop and that clear before it returns
  # (.store_broadcasts()).
  drop <- function(regs) {
    if (length(regs)) {
      store$drop(regs)
    }
  }
  # A failed run waits out the writes and closes the writer's handles
  # before its clear (.run_guard()), as the writes map the readers' regions.
  on.exit(if (!done) .writer_settle(writes), add = TRUE)
  harvest <- function() {
    any <- FALSE
    for (key in names(writes)) {
      w <- writes[[key]]
      if (.task_unresolved(w$h)) {
        next
      }
      if (inherits(w$h$data, "garry_task_failure")) {
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
      if (.read_fits(n, length(writes), live_mb, region_mb, budget_mb)) length(writes) else cap
    },
    poll = harvest,
    cap = cap,
    tl = tl,
    watch = prof,
    task = function(i, a, cg, core, timed) {
      .task_submit(
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
