#' @include passes.R gdal_adapter.R ops.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Single-threaded anvl-native executor (decision D14).
#
# Topo-walk over stages. Per chunk:
#   read (halo-padded GDAL window) -> upload once -> run the jit()'d
#   stage closure (intermediates stay device-side inside the XLA
#   program) -> download at the stage boundary.
#
# anvl's shape/dtype-keyed LRU jit cache IS the kernel cache: a regular
# chunk grid yields at most 4 shapes per stage (D4), and compute stages
# grow their edge chunks to the modal shape (.sv_grow), so a compute
# stage compiles one executable and a reduce_partial stage at most 4.
# reduce_combine runs in plain R on the
# small per-chunk partials. The distributed twin is execute_plan_mirai
# (scheduler.R); this executor is the semantic oracle it is gated
# against.
# ---------------------------------------------------------------------------

#' Drop every kernel this process holds.
#'
#' The cache is keyed on kernel content, so it is only ever a speed
#' optimisation; clearing it costs a recompile and nothing else.
#'
#' @return `NULL`, invisibly.
#' @keywords internal
.exec_jit_clear <- function() {
  rm(list = ls(.daemon_cache, all.names = TRUE), envir = .daemon_cache)
  invisible(NULL)
}

# Can a kernel be reused across runs? Not on macOS, where reuse dispatches
# slower than a fresh compile or stalls (see .host_kernel() and
# .daemon_jit_reset()).
.kernels_outlive_runs <- function() {
  !identical(Sys.info()[["sysname"]], "Darwin")
}

# A kernel the host runs itself. A fresh g_jit() per run hands XLA a
# kernel it has never seen and recompiles it every time (see
# .daemon_kernel()), measured at ~0.29 s per collect on a 4-band index
# pipeline, half the executor's compute time, so a rebuilt but
# structurally identical plan reuses the executable as a daemon does.
#
# macOS: reusing a cached JitFunction across collects dispatches SLOWER
# than a fresh compile there (test-kernel-cache's recompile tripwire:
# second collect 3.8s vs a 2s gate, run 33505350958), and the compounded
# slowdown pushed the CI suite past its elapsed-time kill. Same
# needs-mac-hardware family as the fused-on-reader hang (see
# test-compute-on-read.R). Until debugged on real hardware the host
# cache is not used on Darwin; inline g_jit is exactly the pre-cache
# behavior, which is green there.
.host_kernel <- function(ck, fn, dev) {
  if (!.kernels_outlive_runs()) {
    return(g_jit(fn, device = dev))
  }
  .daemon_kernel(paste0(ck, "#", .default_dtype_tag()), fn, dev)
}

# The stage holding node `nid`: the last, as a spatially reduced root is
# a member of both its partial and combine stages.
.stage_of_node <- function(plan, nid) {
  plan@stages[[max(which(vapply(
    plan@stages,
    function(s) nid %in% s@members,
    logical(1)
  )))]]
}

# Resolve a "warp" stage to the read that actually serves it. An aligned
# same-CRS target needs no warping (see .rio_direct_spec()): read the
# source directly and let RasterIO resample in the same pass. Several
# sources read by nearest neighbour go source by source, directly where
# a source lies on the target's pixels (.mosaic_read_spec()). A Zarr
# store, or other sources together, warp straight into each window
# (gdal_warp_window()); anything else builds the warped VRT. Shared by
# execute_plan() and the distributed scheduler so the two cannot disagree
# about which read they do. `build = FALSE` asks only which: a warped VRT,
# the last resort, comes back as an empty plan, unbuilt.
.warp_read_plan <- function(wnode, snode, build = TRUE) {
  # a collapsed band stack of warps reads its own bands of the source
  band <- if (length(wnode@bands)) wnode@bands else snode@band
  # a coarsened warp, or a decoded mosaic or Zarr array read by nearest
  # neighbour, decodes and averages the nearest read of its sources
  if (
    wnode@coarsen > 1L ||
      (length(snode@decode) &&
        wnode@resampling %in% c("near", "nearest") &&
        (length(snode@decode$src) > 1L ||
          .gdal_is_zarr(snode@decode$src[[1L]])))
  ) {
    return(.coarsen_read_plan(wnode, snode, band))
  }
  if (length(snode@decode)) {
    # a decoded source onto aligned pixels reads its codes and decodes
    # them itself; anything else warps its lookup-table VRT (`path`)
    spec <- .rio_direct_spec(
      snode@decode$src,
      wnode@target_grid,
      wnode@resampling,
      band = band,
      decode = TRUE
    )
    if (!is.null(spec)) {
      spec$decode <- snode@decode
      return(list(
        path = snode@decode$src,
        band = band,
        nodata = numeric(0),
        open_options = character(0),
        scale = numeric(0),
        offset = numeric(0),
        decim = spec
      ))
    }
  }
  if (length(snode@path) > 1L) {
    # a multi-path source (tiles no mosaic can hold): source by source
    # by nearest neighbour, else every source warped straight into each
    # target window
    return(list(
      path = snode@path,
      band = band,
      nodata = snode@nodata,
      open_options = character(0),
      scale = snode@scale,
      offset = snode@offset,
      decim = if (.reads_tile_by_tile(wnode@resampling, wnode@grid@dtype)) {
        .mosaic_read_spec(snode@path, wnode@target_grid, band, snode@nodata)
      },
      resampling = wnode@resampling
    ))
  }
  # A file of the same product as one that had to warp warps too: no need to
  # open it. The grid hides what the VRT holds of the file, its type and row
  # order, so a source that never opened its file builds its own.
  alike <- if (length(snode@stored)) {
    list(snode@grid, snode@stored, snode@scale, snode@offset)
  }
  key <- .warp_vrt_key(alike, band, wnode@target_grid, wnode@resampling, snode@nodata, snode@open_options)
  spec <- if (is.null(key) || is.null(.gdal_cache$warp_vrt[[key]])) {
    .rio_direct_spec(
      snode@path,
      wnode@target_grid,
      wnode@resampling,
      snode@open_options,
      band = band,
      nodata = snode@nodata,
      src_grid = snode@grid
    )
  }
  if (!is.null(spec)) {
    return(list(
      path = snode@path,
      band = band,
      nodata = snode@nodata,
      open_options = snode@open_options,
      scale = snode@scale,
      offset = snode@offset,
      decim = spec
    ))
  }
  if (.gdal_is_zarr(snode@path)) {
    # A Zarr store warps straight into each window from its cached handle
    # (gdal_warp_window(), flagged through `decim`), never through a
    # warped VRT: the VRT reopens the store inside GDAL, losing its
    # decoded chunks between bands and repeating its open's probes.
    return(list(
      path = snode@path,
      band = band,
      nodata = snode@nodata,
      open_options = snode@open_options,
      scale = snode@scale,
      offset = snode@offset,
      decim = list(warp = TRUE),
      resampling = wnode@resampling
    ))
  }
  if (!build) {
    return(list())
  }
  vrt <- gdal_warp_vrt(
    .gti_resampled_path(snode@path, snode@resampling),
    band,
    wnode@target_grid,
    wnode@resampling,
    src_nodata = snode@nodata,
    open_options = snode@open_options,
    alike = alike
  )
  list(
    path = vrt,
    band = seq_along(band),
    nodata = snode@nodata,
    open_options = character(0),
    scale = snode@scale,
    offset = snode@offset,
    decim = NULL,
    warped = TRUE,
    prefetch = .gdal_warp_prefetch_src(
      snode@path,
      snode@grid,
      snode@stored,
      snode@block_dim,
      snode@open_options,
      wnode@resampling,
      vrt
    )
  )
}

# The read behind a coarsened warp (coarsen()), and behind a decoded
# mosaic's nearest read (k = 1): its sources onto the target's k-times
# finer grid as their nearest read takes them (.mosaic_read_spec(); all
# warped together where that declines), decoded through the table and
# averaged by block (gdal_read_window_coarsen()).
.coarsen_read_plan <- function(wnode, snode, band) {
  k <- wnode@coarsen
  dec <- snode@decode
  paths <- if (length(dec)) dec$src else snode@path
  nodata <- if (length(dec)) dec$nodata else snode@nodata
  tg <- wnode@target_grid
  tt <- tg@transform
  d <- tg@dims
  fine <- GridSpec(
    crs = tg@crs,
    transform = c(tt[[1L]], tt[[2L]] / k, 0, tt[[4L]], 0, tt[[6L]] / k),
    extent = tg@extent,
    dims = c(x = d[["x"]] * k, y = d[["y"]] * k),
    dtype = "f32"
  )
  list(
    path = paths,
    band = band,
    nodata = nodata,
    open_options = character(0),
    scale = snode@scale,
    offset = snode@offset,
    resampling = "near",
    decim = list(
      coarsen = k,
      grid = fine,
      parts = .mosaic_read_spec(paths, fine, band, nodata)$parts,
      decode = dec
    )
  )
}

# The block factor of a stage: its WarpNode's coarsen, 1 for any other.
.stage_coarsen <- function(graph, s) {
  if (!identical(s$kind, "warp")) {
    return(1L)
  }
  graph_get(graph, s$members[[1L]])@coarsen
}

# Is a warp stage served by a direct read of its source rather than the
# warper (.warp_read_plan())?
.warp_reads_direct <- function(graph, s) {
  if (!identical(s$kind, "warp")) {
    return(FALSE)
  }
  wnode <- graph_get(graph, s$members[[1L]])
  rp <- .warp_read_plan(wnode, graph_get(graph, wnode@parents[[1L]]), build = FALSE)
  !is.null(rp$decim$fx) || !is.null(rp$decim$coarsen)
}

# A read-only chunk bound for an integer output, read straight into the
# integer planes it writes (gdal_read_int_planes()), or NULL for the f32
# route: a float output, a warp, several sources, a band affine or a
# halo keep it.
.read_int_planes <- function(ra, cg, core, dtype, nodata) {
  if (
    .dtype_family(dtype) == "float" ||
      cg@halo != 0L ||
      length(ra$path) != 1L ||
      isTRUE(ra$decim$warp) ||
      length(ra$decim$decode) > 0L ||
      !is.null(ra$decim$coarsen) ||
      length(ra$scale) > 0L ||
      length(ra$offset) > 0L
  ) {
    return(NULL)
  }
  .gdal_with_retry(
    function() {
      .gdal_read_warped(
        ra,
        gdal_read_int_planes(
          ra$path,
          ra$band,
          core$x_off,
          core$y_off,
          core$x_size,
          core$y_size,
          nodata = ra$nodata,
          out_nodata = nodata,
          open_options = ra$open_options,
          decim = ra$decim
        ),
        core
      )
    },
    what = "read",
    src = ra$path
  )
}

# The read behind a source_read or warp stage: a source's own read
# arguments, or what serves its warp (a direct decimating read or a
# warped VRT, see .warp_read_plan()). One place, so every executor reads
# a stage the same way.
.stage_read_args <- function(graph, s) {
  if (s@kind == "warp") {
    wnode <- graph_get(graph, s@members[[1L]])
    rp <- .warp_read_plan(wnode, graph_get(graph, wnode@parents[[1L]]))
    rp$resampling <- rp$resampling %||% "near"
    return(rp)
  }
  .source_read_args(graph_get(graph, s@members[[1L]]))
}

# How a SourceNode is read: the path wrapped for its resampling (a GTI
# source takes the method through its connection string) and the
# per-read arguments. Shared by the executor and the gradient path, which
# must read a source identically.
.source_read_args <- function(node) {
  if (length(node@decode)) {
    # a decoded source on its own grid reads and decodes its codes
    spec <- .rio_direct_spec(
      node@decode$src,
      node@grid,
      "near",
      band = node@band,
      decode = TRUE
    )
    if (!is.null(spec)) {
      spec$decode <- node@decode
      return(list(
        path = node@decode$src,
        band = node@band,
        nodata = numeric(0),
        open_options = character(0),
        scale = numeric(0),
        offset = numeric(0),
        resampling = "near",
        decim = spec
      ))
    }
  }
  list(
    path = .gti_resampled_path(node@path, node@resampling),
    band = node@band,
    nodata = node@nodata,
    open_options = node@open_options,
    scale = node@scale,
    offset = node@offset,
    resampling = node@resampling,
    # several sources on their own planning grid: source by source, as a
    # nearest warp of them is (.warp_read_plan())
    decim = if (
      length(node@path) > 1L &&
        .reads_tile_by_tile(node@resampling, node@grid@dtype)
    ) {
      .mosaic_read_spec(node@path, node@grid, node@band, node@nodata)
    }
  )
}

# Do several sources take the tile-by-tile mosaic rather than one warp of
# them all? It serves nearest reads, through f32 tile payloads.
.reads_tile_by_tile <- function(resampling, dtype) {
  resampling %in% c("near", "nearest") && dtype %in% .f32_exact_dtypes
}

# Read one halo-padded chunk of `ra` (.stage_read_args()) into a buffer of
# exactly (y + 2H) x (x + 2H): cells beyond the raster edge stay NaN
# (nodata boundary, D8), or 0 for an integer source (.sv_fill). A
# multi-band source (vector `band`, coalesced band stack) reads as a
# (band, y, x) cube; the halo pads the spatial dims only.
.exec_read_padded <- function(ra, cg, core, out = c("matrix", "raw_f32")) {
  out <- rlang::arg_match(out)
  H <- cg@halo
  nb <- length(ra$band)
  # Raw store payloads (D19) only take the halo-free path: padding
  # embeds into a matrix buffer below.
  stopifnot(out == "matrix" || H == 0L)
  w <- chunk_window_with_halo(
    cg,
    core$x_off,
    core$y_off,
    core$x_size,
    core$y_size
  )
  read_one <- function() {
    if (!is.null(ra$decim$coarsen)) {
      return(gdal_read_window_coarsen(
        ra$path,
        ra$band,
        w$x_off,
        w$y_off,
        w$x_size,
        w$y_size,
        decim = ra$decim,
        nodata = ra$nodata,
        out = out,
        scale = ra$scale,
        offset = ra$offset
      ))
    }
    if (length(ra$decim$parts)) {
      return(gdal_read_window_multi(
        ra$path,
        ra$band,
        w$x_off,
        w$y_off,
        w$x_size,
        w$y_size,
        decim = ra$decim,
        nodata = ra$nodata,
        out = out,
        scale = ra$scale,
        offset = ra$offset
      ))
    }
    if (length(ra$path) > 1L || isTRUE(ra$decim$warp)) {
      return(gdal_warp_window(
        ra$path,
        ra$band,
        cg@grid,
        w$x_off,
        w$y_off,
        w$x_size,
        w$y_size,
        resampling = ra$resampling,
        nodata = ra$nodata,
        out = out,
        scale = ra$scale,
        offset = ra$offset,
        open_options = ra$open_options
      ))
    }
    .gdal_read_warped(
      ra,
      gdal_read_window(
        ra$path,
        ra$band,
        w$x_off,
        w$y_off,
        w$x_size,
        w$y_size,
        nodata = ra$nodata,
        open_options = ra$open_options,
        out = out,
        scale = ra$scale,
        offset = ra$offset,
        decim = ra$decim
      ),
      w
    )
  }
  sub <- .gdal_with_retry(read_one, what = "read", src = ra$path)
  if (H == 0L) {
    return(sub)
  }
  fill <- .sv_fill(cg@grid@dtype)
  r0 <- H - w$pad_top
  c0 <- H - w$pad_left
  if (nb > 1L) {
    buf <- array(fill, c(nb, core$y_size + 2L * H, core$x_size + 2L * H))
    buf[, (r0 + 1L):(r0 + w$y_size), (c0 + 1L):(c0 + w$x_size)] <- sub
    return(buf)
  }
  buf <- matrix(fill, core$y_size + 2L * H, core$x_size + 2L * H)
  buf[(r0 + 1L):(r0 + w$y_size), (c0 + 1L):(c0 + w$x_size)] <- sub
  buf
}

# Trim k cells from every side of the LAST two (spatial) dims: matrix,
# (outer, y, x) array, or raw store value.
.exec_trim <- function(x, k) {
  if (k == 0L) {
    return(x)
  }
  if (.sv_is(x)) {
    return(.sv_trim(x, k))
  }
  d <- dim(x)
  if (is.null(d)) {
    return(x)
  }
  if (length(d) == 2L) {
    return(x[(k + 1L):(d[[1L]] - k), (k + 1L):(d[[2L]] - k), drop = FALSE])
  }
  .exec_rank_check(length(d) - 2L)
  x[, (k + 1L):(d[[2L]] - k), (k + 1L):(d[[3L]] - k), drop = FALSE]
}

# Values past (outer, y, x) stay whole: a chunked read, trim or assembly
# handles one outer dim, so a result with more must lose one first.
.exec_rank_check <- function(n_outer) {
  if (n_outer > 1L) {
    .garry_error(
      paste0(
        "this result has ", n_outer, " outer dims, and chunks assemble over one: ",
        "reduce one with reduce_over(), or collapse them with stack_bands()."
      ),
      "garry_plan_error"
    )
  }
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

# Element size of a payload (or dtype string): the store carries f32
# and f64 (design/f64-store.md); everything below keys its byte
# arithmetic on this instead of a hard-coded 4.
.sv_es <- function(v) {
  gdt <- if (is.character(v)) v else attr(v, "gdt")
  switch(
    gdt,
    f64 = 8L,
    f32 = ,
    i32 = 4L,
    i16 = ,
    u16 = 2L,
    i8 = ,
    u8 = 1L,
    .garry_error(.glue("unknown store payload type: {gdt}"), "garry_store_error")
  )
}

# One plane of a payload as the vector GDAL writes: plane `b` of a
# rank-3 (band, y, x) payload, or the whole of a rank-2 one (b = 1).
# Float payloads come back as doubles with NaN folded to `nodata` when
# a sentinel is given; quantized integer payloads as integers. One C
# pass from the byte offset: no R index vector over the bytes (the
# writer-daemon tail of issue #25, 41 ms a plane on a 64-band write).
# `as_int` (an integer output) returns a float plane of whole numbers
# as integers, which GDAL writes to an integer band 4x faster.
.sv_plane_vec <- function(v, b, nodata = numeric(0), as_int = FALSE) {
  d <- .sv_dim(v)
  n <- prod(as.numeric(d[length(d) - 1:0]))
  .Call(
    "garry_sv_plane",
    v,
    (b - 1) * n * .sv_es(v),
    n,
    attr(v, "gdt"),
    as.numeric(nodata),
    as_int,
    PACKAGE = "garry"
  )
}

# Producer-side window slice: rank-2 payloads slice a [y, x] window,
# rank-3 (band, y, x) payloads slice every band plane of the window
# (multi-band coalesced reads). One C row gather per part.
.sv_slicer <- function(v) {
  d <- as.integer(.sv_dim(v))
  es <- .sv_es(v)
  gdt <- attr(v, "gdt")
  nb <- if (length(d) == 3L) d[[1L]] else NULL
  function(r0, c0, nr, nc) {
    out <- .Call(
      "garry_sv_window",
      v,
      d,
      es,
      as.integer(r0),
      as.integer(c0),
      as.integer(nr),
      as.integer(nc),
      PACKAGE = "garry"
    )
    structure(out, gdim = c(nb, as.integer(nr), as.integer(nc)), gdt = gdt)
  }
}

# Consumer-side halo trim. Consumers hold shared (mori) payloads whose
# attributes must not be touched (a write would force a private copy of
# the whole mapping element), so this gathers rows into a fresh vector
# (C, one memcpy a row) instead of taking a dim-stamped view. Trims are
# 0 on the fused hot paths; this runs on align-style plans only.
.sv_trim <- function(v, k) {
  k <- as.integer(k)
  if (k == 0L) {
    return(v)
  }
  d <- as.integer(.sv_dim(v))
  n <- length(d)
  nr <- d[[n - 1L]] - 2L * k
  nc <- d[[n]] - 2L * k
  if (nr <= 0L || nc <= 0L) {
    .garry_error("trim exceeds the payload window", "garry_plan_error")
  }
  out <- .Call(
    "garry_sv_window",
    v,
    d,
    .sv_es(v),
    k,
    k,
    nr,
    nc,
    PACKAGE = "garry"
  )
  d[n - 1:0] <- c(nr, nc)
  structure(out, gdim = d, gdt = attr(v, "gdt"))
}

# Raw payload -> `[y, x]` matrix (sink writes, collect assembly,
# oracle comparisons).
.sv_to_matrix <- function(v) {
  d <- .sv_dim(v)
  matrix(
    readBin(v, numeric(), n = prod(d), size = .sv_es(v)),
    nrow = d[[1L]],
    byrow = TRUE
  )
}

# Raw payload -> R array of any rank (row-major payload into R's
# column-major memory). Lists recurse (reduce_partial exports nest);
# non-store values pass through.
.sv_materialise <- function(v) {
  if (is.list(v)) {
    return(lapply(v, .sv_materialise))
  }
  if (!.sv_is(v)) {
    return(v)
  }
  d <- .sv_dim(v)
  if (length(d) == 2L) {
    return(.sv_to_matrix(v))
  }
  x <- readBin(v, numeric(), n = prod(d), size = .sv_es(v))
  aperm(array(x, dim = rev(d)), rev(seq_along(d)))
}

# What pads a value of this dtype beyond the raster: nodata, which an
# integer buffer holds as 0. QA bits read it as clear.
.sv_fill <- function(dtype) {
  if (.dtype_family(dtype) == "float") NaN else 0
}

# Upload a store value (raw or matrix) after trimming `k`.
# `grow` = c(rows, cols) also pads the trimmed planes (.sv_grow).
.sv_upload <- function(v, k, dtype, dev, grow = NULL) {
  # A negative trim on the raw path would silently read out-of-range
  # raw bytes as 00 (raw OOB subsetting zero-fills) and produce
  # corrupt f32 planes; the matrix path errors naturally. Planner
  # invariants keep k >= 0 today; fail loudly if one breaks.
  stopifnot(k >= 0L)
  v <- .exec_trim(v, k)
  if (!is.null(grow)) {
    v <- .sv_grow(v, grow, dtype)
  }
  if (.sv_is(v)) {
    g_upload_raw(v, attr(v, "gdt"), .sv_dim(v), device = dev)
  } else {
    g_upload(v, dtype, device = dev)
  }
}

# Does a stage run its edge chunks grown to its modal chunk shape
# (.sv_grow, garry.pad_edge_chunks)? Compute stages only: a spatial
# reduction's partials would count the padding. A patch (model) member
# rules it out too: OmniCloudMask normalises over its whole window, so
# padding would move its values.
.stage_grows_edges <- function(graph, s) {
  isTRUE(garry_opt("pad_edge_chunks")) &&
    s@kind == "compute" &&
    !.has_member(graph, s@members, PatchNode)
}

# The chunk shape a grid's kernels run at: the chunk, clipped to the grid.
.modal_chunk <- function(cg) {
  pmin(cg@chunk_dim, cg@grid@dims[c("x", "y")])
}

# The rows and columns chunk `core` (a chunk_iter() row of `cg`) lacks
# of its grid's modal chunk, or NULL for a modal chunk.
.chunk_grow <- function(cg, core) {
  cd <- .modal_chunk(cg)
  g <- as.integer(c(cd[[2L]] - core$y_size, cd[[1L]] - core$x_size))
  if (any(g > 0L)) g
}

# The rank of a value with planes: only a kernel that lost its (y, x)
# plane has none, and its value cannot grow to a chunk.
.sv_rank <- function(d) {
  if (length(d) < 2L) {
    .garry_error(
      "a kernel returned a value with no (y, x) plane: a lazy_map() fn must keep its input's plane.",
      "garry_kernel_error"
    )
  }
  length(d)
}

# Pad a value's planes by `grow` = c(rows, cols) at the bottom and right:
# an edge chunk grown to its stage's modal chunk shape runs the kernel
# already compiled for that shape (.daemon_run_compute_shm). The new
# cells are nodata, as the halo beyond a raster's edge already is
# (.sv_fill), at the dtype `v` uploads as.
.sv_grow <- function(v, grow, dtype) {
  if (.sv_is(v)) {
    d <- as.integer(.sv_dim(v))
    n <- length(d)
    to <- d[n - 1:0] + as.integer(grow)
    fill <- if (attr(v, "gdt") %in% c("f32", "f64")) {
      writeBin(NaN, raw(), size = .sv_es(v))
    } else {
      raw(.sv_es(v))
    }
    out <- .Call(
      "garry_sv_pad",
      v,
      d,
      .sv_es(v),
      fill,
      to[[1L]],
      to[[2L]],
      PACKAGE = "garry"
    )
    d[n - 1:0] <- to
    return(structure(out, gdim = d, gdt = attr(v, "gdt")))
  }
  d <- dim(v)
  n <- .sv_rank(d)
  out <- array(.sv_fill(dtype), c(d[seq_len(n - 2L)], d[n - 1:0] + grow))
  idx <- c(
    rep(list(quote(expr = )), n - 2L),
    list(seq_len(d[[n - 1L]]), seq_len(d[[n]]))
  )
  do.call(`[<-`, c(list(out), idx, list(value = v)))
}

# Cut `grow` = c(rows, cols) from the bottom and right of each value's
# planes: the inverse of .sv_grow on a kernel's outputs. Lists recurse.
.sv_crop <- function(v, grow) {
  if (is.list(v)) {
    return(lapply(v, .sv_crop, grow))
  }
  if (.sv_is(v)) {
    d <- as.integer(.sv_dim(v))
    n <- length(d)
    keep <- d[n - 1:0] - as.integer(grow)
    out <- .Call(
      "garry_sv_window",
      v,
      d,
      .sv_es(v),
      0L,
      0L,
      keep[[1L]],
      keep[[2L]],
      PACKAGE = "garry"
    )
    d[n - 1:0] <- keep
    return(structure(out, gdim = d, gdt = attr(v, "gdt")))
  }
  d <- dim(v)
  n <- .sv_rank(d)
  idx <- c(
    rep(list(quote(expr = )), n - 2L),
    list(seq_len(d[[n - 1L]] - grow[[1L]]), seq_len(d[[n]] - grow[[2L]]))
  )
  do.call(`[`, c(list(v), idx, list(drop = FALSE)))
}

# Download a stage's exports as store values: f32/f64 exports of rank
# >= 2 become raw payloads (no double materialisation; raw f64 is
# bit-identical to the doubles path); scalars and non-float exports
# stay R arrays. Recurses into nested exports (reduce_partial wraps
# its pieces in a list).
.sv_download_exports <- function(res) {
  conv <- function(o) {
    if (.g_traced(o)) {
      if (.g_dtype(o) %in% c("f32", "f64") && length(.g_shape(o)) >= 2L) {
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

# A stage's export dtypes by node key.
.export_dtypes <- function(graph, s) {
  stats::setNames(
    vapply(s@exports, function(e) graph_get(graph, e)@grid@dtype, character(1)),
    vapply(s@exports, .key, character(1))
  )
}

# Padding a SPECIFIC export of a stage carries: source/warp exports the
# stage halo; compute exports their static `export_pads` entry (a
# pre-focal export in a halo stage carries more than the stage tail).
.exec_export_pad <- function(stage, nid) {
  if (stage@kind %in% c("source_read", "warp")) {
    return(stage@halo)
  }
  if (length(stage@export_pads) == 0L) {
    return(0L)
  }
  i <- match(as.integer(nid), stage@exports)
  if (is.na(i)) 0L else stage@export_pads[[i]]
}

# The cells of chunk `core`, padded by `pad`, that lie past the raster on
# each side: c(top, left, bottom, right). A side can hold fewer than `pad`,
# as a chunk smaller than the pad, one in from the edge, reaches past it by
# less. A chunk grown by `grow` (.sv_grow) holds its new cells past it too.
.ring_cells <- function(core, gdims, pad, grow = NULL) {
  grow <- grow %||% c(0L, 0L)
  as.integer(c(
    max(0L, pad - core$y_off),
    max(0L, pad - core$x_off),
    max(0L, core$y_off + core$y_size + pad - gdims[["y"]]) + grow[[1L]],
    max(0L, core$x_off + core$x_size + pad - gdims[["x"]]) + grow[[2L]]
  ))
}

# How a kernel takes .ring_cells() (see .ring_windows()): the input it adds
# to its stage's, or nothing for a kernel that takes none.
.ring_dtype <- "i32"
.ring_shape <- 4L
.ring_input <- function(ring, dev = NULL) {
  if (!is.null(ring)) list(g_upload(ring, .ring_dtype, device = dev))
}

# Nodata for `dtype` (.sv_fill) in the outer `ring` cells of a value's planes.
.mask_cells <- function(v, ring, dtype) {
  d <- dim(v)
  nr <- d[[length(d) - 1L]]
  nc <- d[[length(d)]]
  top <- ring[[1L]]
  left <- ring[[2L]]
  bot <- ring[[3L]]
  right <- ring[[4L]]
  # i64 and u32 arrive as doubles; an R integer stays one
  fill <- if (is.double(v)) .sv_fill(dtype) else 0L
  if (length(d) == 2L) {
    if (top > 0L) {
      v[seq_len(top), ] <- fill
    }
    if (bot > 0L) {
      v[(nr - bot + 1L):nr, ] <- fill
    }
    if (left > 0L) {
      v[, seq_len(left)] <- fill
    }
    if (right > 0L) v[, (nc - right + 1L):nc] <- fill
  } else {
    if (top > 0L) {
      v[, seq_len(top), ] <- fill
    }
    if (bot > 0L) {
      v[, (nr - bot + 1L):nr, ] <- fill
    }
    if (left > 0L) {
      v[,, seq_len(left)] <- fill
    }
    if (right > 0L) v[,, (nc - right + 1L):nc] <- fill
  }
  v
}

# NaN out the beyond-raster margin of a padded chunk value (D22 + D8):
# the ring a padded stage computes past the raster edge starts as NaN
# at the read, but a member fn need not map NaN to NaN (integer casts
# do not), so every stage boundary re-presents beyond-edge cells as
# nodata for `dtype` (.sv_fill), and so does a window reading a member
# inside a stage (.g_mask_ring). Interior chunks return untouched; raw
# payloads materialise (edge chunks only, and only under a nonzero pad).
.exec_mask_edge <- function(v, pad, core, gdims, dtype) {
  pad <- as.integer(pad)
  if (pad == 0L) {
    return(v)
  }
  ring <- .ring_cells(core, gdims, pad)
  if (sum(ring) == 0L) {
    return(v)
  }
  was_raw <- .sv_is(v)
  gdt0 <- if (was_raw) attr(v, "gdt")
  if (was_raw) {
    v <- .sv_materialise(v)
  }
  d <- dim(v)
  v <- .mask_cells(v, ring, dtype)
  # Re-wrap raw payloads (row-major, original element size): leaving the
  # masked edge chunk as R doubles stored 8 B/px while the budget booked
  # the raw element size under-accounts boundary chunks 2x (defect
  # hunt L2).
  if (was_raw) {
    x <- if (length(d) == 2L) {
      as.numeric(t(v))
    } else {
      as.numeric(aperm(v, rev(seq_along(d))))
    }
    return(structure(
      writeBin(x, raw(), size = .sv_es(gdt0)),
      gdim = d,
      gdt = gdt0
    ))
  }
  v
}

# Stage device -> anvl device argument: "cpu" means anvl's default
# device (NULL), anything else passes through (e.g. "cuda").
.exec_device <- function(device) {
  if (identical(device, "cpu")) NULL else device
}

# Per-input fetch metadata for a compute/reduce_partial stage. Stage
# outputs are always stored at the plan-wide compute chunk granularity
# (coarse source reads split on write), so consumers index by chunk.
.exec_in_meta <- function(graph, s, plan_stages, node_stage = NULL) {
  # `node_stage` (optional): node id -> producing stage id, first-wins
  # as the Find below. The linear Find is O(stages x members) per input
  # node: the distributed task build passes the precomputed index.
  producer_of <- function(nid) {
    if (!is.null(node_stage)) {
      return(plan_stages[[node_stage[[nid]]]])
    }
    Find(function(p) nid %in% p@members, plan_stages)
  }
  lapply(s@input_nodes, function(nid) {
    prod <- producer_of(nid)
    list(
      id = prod@id,
      pad = .exec_export_pad(prod, nid),
      dtype = graph_get(graph, nid)@grid@dtype
    )
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
.exec_split_cg <- function(plan, s, consumer_ids = NULL) {
  # `consumer_ids` (optional): stage ids consuming s, precomputed by
  # the caller: the Filter below is O(stages) per call, O(stages^2)
  # over a task build.
  cons <- if (is.null(consumer_ids)) {
    Filter(
      function(t2) {
        s@id %in% t2@inputs && t2@kind %in% c("compute", "reduce_partial")
      },
      plan@stages
    )
  } else {
    Filter(
      function(t2) t2@kind %in% c("compute", "reduce_partial"),
      plan@stages[unique(consumer_ids)]
    )
  }
  if (length(cons) == 0L) {
    return(NULL)
  }
  cg <- cons[[1L]]@chunks
  if (all(cg@chunk_dim == s@chunks@chunk_dim)) {
    return(NULL)
  }
  stopifnot(all(s@chunks@chunk_dim %% cg@chunk_dim == 0L))
  ChunkGrid(
    grid = s@grid,
    chunk_dim = cg@chunk_dim,
    block_dim = s@chunks@block_dim,
    halo = s@chunks@halo
  )
}

# The chunk grid a stage's OUTPUT chunks are stored under: the split
# (compute-chunk) grid for a coarse-read source with compute consumers,
# else the stage's own. Every consumer of a stage's chunk list by index
# (sink assembly, streamed writes) must iterate this grid, or a split
# source that is also a sink lands one part per read window (issue
# #25: a coalesced band stack written beside the reduce that reads it).
.stage_out_chunks <- function(plan, s) {
  .exec_split_cg(plan, s) %||% s@chunks
}

# Compute-chunk rows covered by read-chunk row `r` (both tile the same
# grid; read boundaries land on compute boundaries).
.exec_split_members <- function(its, rrow) {
  which(
    its$x_off >= rrow$x_off &
      its$x_off < rrow$x_off + rrow$x_size &
      its$y_off >= rrow$y_off &
      its$y_off < rrow$y_off + rrow$y_size
  )
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
# tail overlaps the next band's read drain. An invariant (dask.order
# solves the same problem with static priorities), gated by
# test-launch-order.R.
.stage_launch_order <- function(plan) {
  n <- length(plan@stages)
  state <- integer(n) # 0 unvisited, 1 on stack, 2 emitted
  ord <- integer(n)
  pos <- 0L
  visit <- function(i) {
    if (state[[i]] == 2L) {
      return(invisible(NULL))
    }
    if (state[[i]] == 1L) {
      .garry_error("stage graph has a cycle", "garry_plan_error")
    }
    state[[i]] <<- 1L
    for (j in plan@stages[[i]]@inputs) {
      visit(j)
    }
    state[[i]] <<- 2L
    pos <<- pos + 1L
    ord[[pos]] <<- i
    invisible(NULL)
  }
  visit(plan@sink)
  # Completeness: stages unreachable from the sink (none in current
  # plans) still execute, after the sink's subtree.
  for (i in seq_len(n)) {
    if (state[[i]] != 2L) visit(i)
  }
  ord
}

# Write one sink chunk to an open output dataset. 2D chunks write to
# band 1; (outer, y, x) chunks write one GTiff band per outer layer
# (t or band, D17). Padding (source/warp sinks, or D22 padded compute
# exports) trims off first.
.exec_write_chunk <- function(ds, x_off, y_off, ch, sink_pad, dtype, nodata) {
  ch <- .exec_trim(ch, sink_pad)
  if (.sv_is(ch)) {
    d <- .sv_dim(ch)
    if (length(d) == 2L) {
      gdal_write_window(ds, x_off, y_off, ch, dtype = dtype, nodata = nodata)
    } else {
      # Row-major (band, y, x) payload: each band's plane is one
      # contiguous byte range the write takes by offset.
      .exec_rank_check(length(d) - 2L)
      for (b in seq_len(d[[1L]])) {
        gdal_write_window(
          ds,
          x_off,
          y_off,
          ch,
          dtype = dtype,
          nodata = nodata,
          band = b,
          plane = b
        )
      }
    }
  } else if (is.matrix(ch)) {
    gdal_write_window(ds, x_off, y_off, ch, dtype = dtype, nodata = nodata)
  } else {
    for (b in seq_len(dim(ch)[[1L]])) {
      m <- ch[b, , , drop = FALSE]
      dim(m) <- dim(ch)[2:3]
      gdal_write_window(
        ds,
        x_off,
        y_off,
        m,
        dtype = dtype,
        nodata = nodata,
        band = b
      )
    }
  }
  invisible(NULL)
}

.exec_check_writable <- function(ch, n_chunks) {
  if (.sv_is(ch)) {
    if (n_chunks == 1L && length(.sv_dim(ch)) < 2L) {
      .garry_error(
        "cannot write a scalar reduction to a raster file",
        "garry_plan_error"
      )
    }
    return(invisible(NULL))
  }
  rank3 <- is.array(ch) && length(dim(ch)) == 3L
  if (n_chunks == 1L && !is.matrix(ch) && !rank3) {
    .garry_error(
      "cannot write a scalar reduction to a raster file",
      "garry_plan_error"
    )
  }
}

# Sink write-quantization spec from a wspec + nodata: NULL unless the
# write quantizes (scale present). nodata is optional (the historical
# writer contract): absent, g_quantize checks the chunk for NaN on
# device and errors -- NaN cannot survive the integer cast.
.exec_wq <- function(wspec, nodata) {
  if (is.null(wspec) || length(wspec$scale) != 1L) {
    return(NULL)
  }
  list(
    scale = wspec$scale,
    offset = if (length(wspec$offset) == 1L) wspec$offset else 0,
    nodata = if (length(nodata) == 1L) {
      as.numeric(nodata)
    } else {
      numeric(0)
    },
    dtype = wspec$dtype
  )
}

# Quantize one sink chunk value on device (g_quantize: the ONE write
# quantizer, so every route yields byte-identical digital numbers).
# Only a sink no producer quantized reaches this: a cleared sink streams
# straight to the file (.wq_stream_ok()).
.exec_quantize_value <- function(v, wq) {
  if (is.null(wq)) {
    return(v)
  }
  dev <- if (.sv_is(v)) {
    g_upload_raw(v, attr(v, "gdt"), .sv_dim(v))
  } else {
    g_upload(v, "f32")
  }
  q <- g_quantize(dev, wq$scale, wq$offset, wq$nodata, wq$dtype)
  if (.sv_is(v)) g_download_raw(q) else g_download(q)
}

# Create a sink's output as its write spec says.
.sink_output <- function(path, grid, nodata, band_names, wspec) {
  gdal_create_output(
    path,
    grid,
    nodata = nodata,
    band_names = band_names,
    dtype = wspec$dtype,
    options = wspec$options,
    scale = wspec$scale,
    offset = wspec$offset
  )
}

# Write sink chunks to a GTiff (single-threaded executor; the
# distributed scheduler streams chunks through .exec_write_chunk as
# they land instead).
.exec_write_sink <- function(
  chunks,
  it,
  grid,
  path,
  nodata,
  band_names,
  sink_pad,
  wspec = NULL
) {
  .exec_check_writable(chunks[[1L]], nrow(it))
  nodata <- as.numeric(nodata)
  ds <- .sink_output(path, grid, nodata, band_names, wspec)
  on.exit(try(ds$close(), silent = TRUE), add = TRUE)
  wdt <- wspec$dtype %||% grid@dtype
  wq <- .exec_wq(wspec, nodata)
  for (j in seq_len(nrow(it))) {
    ch <- .exec_quantize_value(chunks[[j]], wq)
    .exec_write_chunk(ds, it$x_off[j], it$y_off[j], ch, sink_pad, wdt, nodata)
  }
  gdal_close_output(ds, path)
}

# Assemble sink chunks into the full raster; stacks assemble to
# (t, y, x) arrays (D17), 2D sinks to [y, x] matrices.
.exec_assemble <- function(chunks, it, grid, sink_pad) {
  dims <- grid@dims
  outer_dims <- .grid_outer(grid)
  if (length(outer_dims) == 0L) {
    full <- matrix(NA_real_, dims[["y"]], dims[["x"]])
    # raw f32 chunks (the distributed store) copy into place in one C
    # pass each; f32 -> double is exact, so the values are those of the
    # matrix route below
    if (all(vapply(chunks, function(v) .sv_is(v) && attr(v, "gdt") == "f32", logical(1)))) {
      for (j in seq_len(nrow(it))) {
        v <- .exec_trim(chunks[[j]], sink_pad)
        d <- .sv_dim(v)
        .Call(
          "garry_f32_into_colmajor",
          full,
          v,
          as.numeric(c(it$y_off[j], it$x_off[j], 0)),
          as.numeric(c(dims[["y"]], dims[["x"]], 1, 1, d[[1L]], d[[2L]])),
          PACKAGE = "garry"
        )
      }
      return(full)
    }
    chunks <- lapply(chunks, .sv_materialise)
    for (j in seq_len(nrow(it))) {
      full[
        (it$y_off[j] + 1L):(it$y_off[j] + it$y_size[j]),
        (it$x_off[j] + 1L):(it$x_off[j] + it$x_size[j])
      ] <-
        .exec_trim(chunks[[j]], sink_pad)
    }
    return(full)
  }
  .exec_rank_check(length(outer_dims))
  chunks <- lapply(chunks, .sv_materialise)
  full <- array(NA_real_, c(outer_dims[[1L]], dims[["y"]], dims[["x"]]))
  for (j in seq_len(nrow(it))) {
    full[,
      (it$y_off[j] + 1L):(it$y_off[j] + it$y_size[j]),
      (it$x_off[j] + 1L):(it$x_off[j] + it$x_size[j])
    ] <-
      .exec_trim(chunks[[j]], sink_pad)
  }
  full
}


# Resolve the band descriptions for one sink of a multi-export plan:
# a NAMED LIST keyed by sink name (per-sink descriptions, e.g. ragged
# time groups), a plain vector (every sink), else the sink grid's own
# band labels (carried from lazy_stack/stack_bands layer names).
.sink_band_names <- function(band_names, nm, ngrid) {
  if (is.list(band_names)) {
    return(band_names[[nm]])
  }
  band_names %||% .grid_layer_labels(ngrid)
}

# Per-sink output paths of a multi-sink write, named by sink: an
# existing directory holds "<sink>.tif" files, otherwise `path` is
# already named by sink.
.sink_paths <- function(path, sinks) {
  if (length(path) == 1L && dir.exists(path)) {
    return(stats::setNames(file.path(path, paste0(sinks, ".tif")), sinks))
  }
  stats::setNames(as.character(path[sinks]), sinks)
}

# Shared host-side sink tail: multi-export and single-sink assembly /
# write, used by BOTH executors (the single-threaded oracle and the
# scheduler's post-drain host phase). `chunks_of(stage)` returns the
# stage's list of per-chunk EXPORT lists (reduce_combine: a one-element
# list holding the combined exports). `streamed_path(nm)`, when given,
# returns the on-disk path for a sink that already streamed chunk by
# chunk, else NULL.
.exec_sink_tail <- function(
  plan,
  graph,
  chunks_of,
  path,
  nodata,
  band_names,
  streamed_path = NULL,
  wspec = NULL
) {
  one_sink <- function(st, nid, grid, p, bands) {
    chunks <- lapply(chunks_of(st), `[[`, .key(nid))
    it <- chunk_iter(.stage_out_chunks(plan, st))
    pad <- .exec_export_pad(st, nid)
    if (!is.null(p)) {
      return(.exec_write_sink(chunks, it, grid, p, nodata, bands, pad, wspec))
    }
    if (nrow(it) > 1L) {
      return(.exec_assemble(chunks, it, grid, pad))
    }
    v <- .exec_trim(.sv_materialise(chunks[[1L]]), pad)
    if (is.matrix(v) && all(dim(v) == c(1L, 1L))) v[1L, 1L] else v
  }
  if (length(plan@sinks) <= 1L) {
    sink <- plan@stages[[plan@sink]]
    return(one_sink(sink, sink@members[[length(sink@members)]], sink@grid, path, band_names))
  }
  res <- lapply(seq_along(plan@sinks), function(k) {
    nid <- plan@sinks[[k]]
    nm <- names(plan@sinks)[[k]]
    streamed <- if (!is.null(path) && !is.null(streamed_path)) streamed_path(nm)
    if (!is.null(streamed)) {
      return(streamed)
    }
    # the exported node's grid, not the stage tail's
    ngrid <- graph_get(graph, nid)@grid
    one_sink(
      .stage_of_node(plan, nid),
      nid,
      ngrid,
      if (!is.null(path)) .sink_paths(path, nm)[[nm]],
      .sink_band_names(band_names, nm, ngrid)
    )
  })
  names(res) <- names(plan@sinks)
  if (is.null(path)) res else invisible(.sink_paths(path, names(plan@sinks)))
}

#' Execute a Plan on the anvl backend (single process).
#'
#' Runs every stage of a [plan_lazy()] plan in the current R session.
#' [collect()] is the normal user entry point; call this directly only
#' when executing a plan by hand.
#'
#' @param plan A `Plan`.
#' @param path Optional GTiff destination: the sink raster is written
#'   chunk by chunk instead of returned in memory.
#' @param nodata Optional sentinel recorded in the output and used to
#'   demote NaN on write (required for integer outputs containing NaN).
#' @param band_names Optional character vector of band descriptions written to
#'   the output bands (multiband GTiff).
#' @param wspec Optional sink write spec from [write_tif()]: a list of
#'   `dtype` (output dtype override), `scale`/`offset` (quantization
#'   affine applied per chunk at the sink boundary) and `options`
#'   (creation options).
#' @return The sink stage's value (matrix for raster sinks, scalar for
#'   global reductions), or `path` invisibly when writing.
#' @seealso [collect()], [execute_plan_mirai()], [plan_lazy()]
#' @export
execute_plan <- function(
  plan,
  path = NULL,
  nodata = NULL,
  band_names = NULL,
  wspec = NULL
) {
  .garry_opt_check()
  graph <- plan@graph
  out <- vector("list", length(plan@stages))

  # A source stage consumed only by warp stages never needs reading:
  # the warper pulls pixels from the file itself.
  warp_only <- .placement_scan(plan)$warp_only

  for (s in plan@stages[.stage_launch_order(plan)]) {
    it <- chunk_iter(s@chunks)

    if (s@kind %in% c("source_read", "warp")) {
      if (s@kind == "source_read" && warp_only[[s@id]]) {
        next
      }
      ra <- .stage_read_args(graph, s)
      key <- .key(s@members[[1L]])
      split_cg <- .exec_split_cg(plan, s)
      if (is.null(split_cg)) {
        out[[s@id]] <- lapply(seq_len(nrow(it)), function(j) {
          stats::setNames(
            list(.exec_read_padded(ra, s@chunks, it[j, ])),
            key
          )
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
          buf <- .exec_read_padded(ra, s@chunks, it[r, ])
          rank3 <- length(dim(buf)) == 3L
          for (j in .exec_split_members(its, it[r, ])) {
            r0 <- its$y_off[[j]] - it$y_off[[r]]
            c0 <- its$x_off[[j]] - it$x_off[[r]]
            part <- if (rank3) {
              buf[,
                (r0 + 1L):(r0 + its$y_size[[j]] + H2),
                (c0 + 1L):(c0 + its$x_size[[j]] + H2),
                drop = FALSE
              ]
            } else {
              buf[
                (r0 + 1L):(r0 + its$y_size[[j]] + H2),
                (c0 + 1L):(c0 + its$x_size[[j]] + H2),
                drop = FALSE
              ]
            }
            out[[s@id]][[j]] <- stats::setNames(list(part), key)
          }
        }
      }
    } else if (s@kind %in% c("compute", "reduce_partial")) {
      dev <- .exec_device(s@device)
      jf <- .host_kernel(
        paste0(.stage_kernel_sig(graph, s), "@", s@device),
        s@fn,
        dev
      )
      in_meta <- .exec_in_meta(graph, s, plan@stages)
      okeys <- vapply(s@exports, .key, character(1))
      epads <- if (length(s@export_pads)) {
        stats::setNames(as.integer(s@export_pads), okeys)
      } else {
        integer(0)
      }
      edtypes <- .export_dtypes(graph, s)
      gdims <- s@grid@dims
      grows <- .stage_grows_edges(graph, s)
      takes_ring <- .takes_ring(graph, s)
      out[[s@id]] <- lapply(seq_len(nrow(it)), function(j) {
        # an edge chunk runs the modal chunk's kernel (.sv_grow)
        grow <- if (grows) .chunk_grow(s@chunks, it[j, ])
        inputs <- lapply(seq_along(s@input_nodes), function(k) {
          meta <- in_meta[[k]]
          v <- out[[meta$id]][[j]][[.key(s@input_nodes[[k]])]]
          extra <- meta$pad - (s@halo + s@out_pad)
          stopifnot(extra >= 0L)
          v <- .exec_trim(v, extra)
          if (!is.null(grow)) {
            v <- .sv_grow(v, grow, meta$dtype)
          }
          g_upload(v, meta$dtype, device = dev)
        })
        if (takes_ring) {
          ring <- .ring_cells(it[j, ], gdims, s@halo + s@out_pad, grow)
          inputs <- c(inputs, .ring_input(ring, dev))
        }
        res <- g_download(jf(inputs))
        if (!is.null(grow)) {
          res <- .sv_crop(res, grow)
        }
        # The jit cache shares one wrapper across structurally identical
        # stages, and the wrapper's export NAMES belong to whichever
        # stage compiled it, so rename positionally (exports are
        # ascending in every composed closure). Same contract as the
        # daemon compute body.
        names(res) <- okeys
        if (any(epads > 0L)) {
          for (k2 in names(res)) {
            res[[k2]] <- .exec_mask_edge(
              res[[k2]],
              epads[[k2]],
              it[j, ],
              gdims,
              edtypes[[k2]]
            )
          }
        }
        res
      })
    } else if (s@kind == "reduce_combine") {
      key <- .key(s@members[[1L]])
      partials <- lapply(out[[s@inputs[[1L]]]], `[[`, key)
      out[[s@id]] <- list(s@fn(partials))
    } else {
      .garry_error(
        paste0("stage kind not executable: ", s@kind),
        "garry_not_implemented_error"
      )
    }
  }

  .exec_sink_tail(
    plan,
    graph,
    chunks_of = function(st) out[[st@id]],
    path = path,
    nodata = nodata,
    band_names = band_names,
    wspec = wspec
  )
}
