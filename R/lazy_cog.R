#' @include dataset.R gdal_adapter.R lazy_raster.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# lazy_cog: the specialist multi-band COG read path. garry's general read
# (lazy_dataset / lazy_source) is single-band per source (BANDS=1 warp-on-read),
# so a geo-embedding stack (tens of bands in one file, e.g. Alpha Earth) reads
# slowly -- one open per band. lazy_cog routes such reads through cptkirk, whose
# async-tiff reader opens each tile once and streams the band planes
# concurrently, warping all bands in one pass into a native-dtype buffer
# (ck_warp_to_buffer). It is LAZY: construction records the read as a "CK:"
# source and fetches nothing; at collect() a pre-pass (.ck_resolve) fetches once
# per source set, stages the native BSQ buffer as a raw .bin + VRTRawRasterBand
# VRT, and rewrites the source paths so both executors read the VRT unchanged.
# The dequant fuses on read. cptkirk is a Suggests dependency, guarded here.
# ---------------------------------------------------------------------------

# Per-process registry: a "CK:<hash>" path -> the fetch spec. Populated by
# lazy_cog() and read by .ck_resolve(), both in the main process; daemons only
# ever see the staged VRT, never the CK: path, so this never crosses a process
# boundary.
.ck_registry <- new.env(parent = emptyenv())

.ck_register <- function(srcs, bands, resampling, nodata, grid) {
  spec <- list(srcs = srcs, bands = bands, resampling = resampling,
               nodata = if (length(nodata)) as.numeric(nodata) else numeric(0),
               te = as.numeric(grid@extent),
               ts = c(unname(grid@dims[["x"]]), unname(grid@dims[["y"]])),
               crs = grid@crs)
  key <- rlang::hash(spec)                  # identical reads dedup to one fetch
  .ck_registry[[key]] <- spec
  paste0("CK:", key)
}

.ck_lookup <- function(rpath) .ck_registry[[sub("^CK:", "", rpath)]]

#' Read COGs into a lazy dataset via the cptkirk engine.
#'
#' The cptkirk read path, a drop-in alternative to [lazy_dataset()] that differs
#' only in the engine: both build the same `LazyDataset` and support the same
#' `mask()` / `reduce_over()` / `collect()` verbs, but `lazy_cog` reads each
#' source set through [cptkirk](https://belian-earth.github.io/cptkirk/) -- its
#' async-tiff reader opens each tile once and streams the band planes
#' concurrently. cptkirk's advantage is intra-file band concurrency, so it wins
#' on multi-band COGs (geo-embedding stacks such as Alpha Earth); on single-band
#' assets it works but has no lever GDAL lacks (use [lazy_dataset()] there).
#'
#' Two input forms:
#' * a `stac_sources()`-style dataframe (`location`/`datetime`/`asset`) plus
#'   `assets` -- a band per named asset, a per-`granularity` time slice per date,
#'   exactly the [lazy_dataset()] shape (mirrors its signature);
#' * a character path or vector of a single (multi-band) COG or a mosaic of
#'   tiles -- one time slice, a band per selected source band.
#'
#' The read is LAZY: construction fetches nothing. At [collect()] each source set
#' (one asset-slice, or the single COG's bands) is fetched together in one
#' cptkirk pass, staged as a grid-aligned native-dtype raster, and read from
#' there. The source nodata sentinel is carried through so those pixels read as
#' NaN. `dequant` fuses a decode onto the read (e.g. [dequantize_aef()]).
#'
#' @param sources A `stac_sources()`-style dataframe for the time-series form, or
#'   a COG path / character vector of tiles (remote `http(s)://` or `/vsicurl/`)
#'   for the single form.
#' @param grid Target `GridSpec`.
#' @param assets Asset names to read (dataframe form; a band each).
#' @param bands Source band indices (single-COG form; default: all).
#' @param dequant Optional garry map `fn(x)` applied per value band and fused at
#'   `collect()` (e.g. [dequantize_aef()]).
#' @param resampling GDAL resampling (default `"near"`, right for quantised
#'   codes).
#' @param names Optional band names (single-COG form; default `b<index>`).
#' @param mask_asset Optional QA asset carried through for [mask()] (dataframe
#'   form).
#' @param granularity Time-slice granularity, e.g. `"day"` (dataframe form).
#' @param sort_field Overlap-resolution field for per-slice mosaics (dataframe
#'   form).
#' @param nodata Optional nodata override: one value, or a named vector per asset
#'   (dataframe form).
#' @param lon Optional longitude for local-time slicing (dataframe form).
#' @return A `LazyDataset`.
#' @export
lazy_cog <- function(sources, grid, assets = NULL, bands = NULL, dequant = NULL,
                     resampling = "near", names = NULL, mask_asset = NULL,
                     granularity = "day", sort_field = "datetime",
                     nodata = NULL, lon = NULL) {
  rlang::check_installed("cptkirk",
                         reason = "for lazy_cog(), the cptkirk read engine.")
  .assert_class(grid, GridSpec, "GridSpec")
  if (is.data.frame(sources))
    return(.lazy_cog_series(sources, grid, assets, mask_asset, granularity,
                            sort_field, nodata, dequant, resampling, lon))
  .lazy_cog_single(as.character(sources), grid, bands, dequant, resampling, names)
}

# Single (multi-band) COG or tile mosaic -> one time slice, a band per selected
# source band. Reads at the source's NATIVE dtype (the grid fixes geometry, not
# the read type): an integer source carrying a `nodata` then promotes to f32 with
# the sentinel as NaN (D8), so the decode never sees it.
.lazy_cog_single <- function(path, grid, bands, dequant, resampling, names) {
  nb <- gdal_band_count(path[[1L]])
  bands <- if (is.null(bands)) seq_len(nb) else as.integer(bands)
  if (length(bands) < 1L) cli::cli_abort("{.arg bands} selects no bands.")
  nd  <- .src_nodata(path[[1L]])                            # dynamic sentinel
  sdt <- gdal_grid_spec(path[[1L]], band = 1L)$grid@dtype
  ckpath <- .ck_register(path, bands, resampling, nd, grid)
  rgrid <- if (!identical(sdt, grid@dtype)) .grid_retype(grid, sdt) else grid
  ndv <- if (length(nd)) as.numeric(nd) else NULL
  g   <- graph_new()
  nm  <- names %||% paste0("b", bands)
  layers <- stats::setNames(lapply(seq_along(bands), function(i) {
    lr <- lazy_source(ckpath, band = i, graph = g, grid = rgrid, nodata = ndv)
    if (!is.null(dequant)) lr <- lazy_map(lr, fn = dequant, dtype = "f32")
    lr
  }), nm)
  as_dataset(layers)
}

# Time-series form: mirror lazy_dataset(). A band per named asset; a per-slice CK:
# source over that asset-slice's items (cptkirk mosaics them), instead of a GTI +
# GDAL warp-on-read. mask()/reduce_over()/collect() are engine-agnostic dataset
# ops, so they work unchanged; .ck_resolve coalesces per asset-slice source set.
.lazy_cog_series <- function(sources, grid, assets, mask_asset, granularity,
                             sort_field, nodata, dequant, resampling, lon) {
  if (is.null(assets) || length(assets) < 1L)
    cli::cli_abort("{.arg assets} must name at least one asset (dataframe form).")
  all_assets <- unique(c(assets, mask_asset))
  sources <- stac_time_slices(sources, granularity, lon = lon)
  resolve_nodata <- function(a, file_nd) {
    fnd <- if (length(file_nd) == 1L) file_nd else NULL
    if (is.null(nodata)) return(fnd)
    if (!is.null(names(nodata)))
      return(if (a %in% names(nodata)) unname(nodata[[a]]) else fnd)
    as.numeric(nodata)                          # scalar for every asset
  }
  g <- graph_new()
  bands <- list()
  for (a in all_assets) {
    a_rows <- sources[sources$asset == a, , drop = FALSE]
    if (!nrow(a_rows)) cli::cli_abort("No sources for asset {.val {a}}.")
    first   <- a_rows$location[[1L]]
    nd      <- resolve_nodata(a, .src_nodata(first))
    sdt     <- gdal_grid_spec(first, band = 1L)$grid@dtype
    rgrid   <- if (!identical(sdt, grid@dtype)) .grid_retype(grid, sdt) else grid
    ndv     <- if (length(nd)) as.numeric(nd) else NULL
    is_mask <- !is.null(mask_asset) && a %in% mask_asset
    slices  <- sort(unique(a_rows$slice))
    layers  <- lapply(slices, function(sl) {
      items  <- a_rows$location[a_rows$slice == sl][order(
        a_rows$datetime[a_rows$slice == sl])]
      ckpath <- .ck_register(items, 1L, resampling, nd, grid)
      lr <- lazy_source(ckpath, band = 1L, graph = g, grid = rgrid, nodata = ndv)
      if (!is.null(dequant) && !is_mask) lr <- lazy_map(lr, fn = dequant, dtype = "f32")
      lr
    })
    names(layers) <- slices
    bands[[a]] <- layers
  }
  bands <- bands[all_assets]
  LazyDataset(graph = g, bands = bands,
              mask_asset = if (is.null(mask_asset)) character(0)
                           else as.character(mask_asset),
              steps = list(.step("source", "source",
                                 detail = max(vapply(bands, length, 1L)))))
}

# Collect-time pre-pass: fetch every "CK:" source set once (all its bands in one
# ck_warp_to_buffer), stage the native BSQ buffer as a raw .bin + VRTRawRasterBand
# VRT, and rewrite the source-node paths to the VRT so the executors read it as
# an ordinary grid-aligned GDAL source. Returns the (mutated) plan and a staging
# root to unlink after collect, or root = NULL when there is nothing to resolve.
.ck_resolve <- function(p) {
  g   <- p@graph
  ids <- Filter(function(id) {
    n <- graph_get(g, id)
    S7::S7_inherits(n, SourceNode) && startsWith(n@path, "CK:")
  }, graph_ids(g))
  if (!length(ids)) return(list(plan = p, root = NULL))
  keys <- vapply(ids, function(id) graph_get(g, id)@path, "")
  # Stage on tmpfs (/dev/shm) when available: RAM-backed, so no disk round-trip,
  # AND a real shared path the mirai daemons can read -- unlike /vsimem, which is
  # per-process and invisible across the daemon boundary. Matches prepare_fetch.
  base <- if (dir.exists("/dev/shm")) "/dev/shm" else tempdir()
  root <- file.path(base, paste0("garry-ck-", rlang::hash(sort(unique(keys)))))
  dir.create(root, showWarnings = FALSE, recursive = TRUE)
  for (k in unique(keys)) {
    spec <- .ck_lookup(k)
    if (is.null(spec))
      cli::cli_abort("Unresolved {.fn lazy_cog} source {.val {k}}.")
    vrt <- .ck_fetch(spec, root)
    for (id in ids[keys == k]) {
      n <- graph_get(g, id)
      n@path <- vrt
      graph_replace(g, id, n)
    }
  }
  list(plan = p, root = root)
}

# The one cptkirk-dependent step: fetch+warp the source set's selected bands onto
# the target grid into a native-dtype BSQ buffer, staged as a raw .bin described
# by a VRTRawRasterBand VRT (relativeToVRT sibling, satisfying GDAL's raw-band
# security gate). Returns the VRT path.
.ck_fetch <- function(spec, root) {
  res <- cptkirk::ck_warp_to_buffer(
    spec$srcs, t_srs = spec$crs, te = spec$te, ts = spec$ts,
    bands = spec$bands, r = spec$resampling,
    fill = if (length(spec$nodata)) spec$nodata else NULL)
  sub <- file.path(root, substr(rlang::hash(spec), 1L, 16L))
  dir.create(sub, showWarnings = FALSE)
  bin <- file.path(sub, "buf.bin")
  writeBin(res$data, bin)
  vrt <- file.path(sub, "buf.vrt")
  ndv <- if (length(spec$nodata)) res$nodata else NULL
  writeLines(.raw_bsq_vrt_xml(
    basename(bin), res$nx, res$ny,
    paste(sprintf("%.16g", res$geotransform), collapse = ", "),
    res$crs, res$dtype, res$nbands, ndv), vrt)
  vrt
}

# Read the source's band-1 nodata sentinel (whatever it is), or numeric(0) if the
# source declares none. All bands are assumed to share one sentinel (the case for
# geo-embedding stacks), matching ck_warp_to_buffer's single-fill model. Via the
# adapter (gdal_grid_spec) -- garry keeps gdalraster:: calls out of the cube code.
.src_nodata <- function(path) {
  nd <- gdal_grid_spec(path, band = 1L)$nodata
  if (is.null(nd) || length(nd) == 0L || is.na(nd)) numeric(0) else as.numeric(nd)
}

# Bytes per sample for a GDAL data-type name.
.gdal_dtype_bytes <- function(dt) {
  b <- c(Byte = 1L, Int8 = 1L, UInt16 = 2L, Int16 = 2L, UInt32 = 4L,
         Int32 = 4L, UInt64 = 8L, Int64 = 8L, Float32 = 4L, Float64 = 8L)[[dt]]
  if (is.null(b)) cli::cli_abort("Unsupported buffer dtype {.val {dt}}.")
  b
}

# Build a VRTRawRasterBand dataset XML over a raw band-sequential (BSQ) buffer, so
# GDAL reads it with zero decode. Band b's plane starts at (b-1) * nx * ny * bytes;
# pixels are row-major within it. `src` is the .bin basename, referenced as a
# relativeToVRT sibling (the VRT must be written beside it): GDAL refuses a raw
# band pointing at an arbitrary absolute path unless the source is a sibling/child
# of the VRT (or GDAL_VRT_RAWRASTERBAND_ALLOWED_SOURCE is set), which this
# satisfies rather than loosening the global config.
.raw_bsq_vrt_xml <- function(src, nx, ny, gt_csv, wkt, dtype, nbands,
                             nodata = NULL) {
  bytes <- .gdal_dtype_bytes(dtype)
  plane <- as.numeric(nx) * as.numeric(ny) * bytes
  ndxml <- if (!is.null(nodata))
    sprintf("\n    <NoDataValue>%s</NoDataValue>",
            format(nodata, scientific = FALSE)) else ""
  bands_xml <- vapply(seq_len(nbands), function(b) sprintf(paste0(
    '  <VRTRasterBand dataType="%s" band="%d" subClass="VRTRawRasterBand">',
    '\n    <SourceFilename relativeToVRT="1">%s</SourceFilename>',
    '\n    <ImageOffset>%.0f</ImageOffset>',
    '\n    <PixelOffset>%d</PixelOffset>',
    '\n    <LineOffset>%d</LineOffset>%s',
    '\n  </VRTRasterBand>'),
    dtype, b, src, (b - 1) * plane, bytes, as.integer(nx * bytes), ndxml), "")
  sprintf(paste0(
    '<VRTDataset rasterXSize="%d" rasterYSize="%d">',
    '\n  <SRS>%s</SRS>\n  <GeoTransform>%s</GeoTransform>\n%s\n</VRTDataset>'),
    nx, ny, wkt, gt_csv, paste(bands_xml, collapse = "\n"))
}

#' Dequantize Alpha Earth (AEF) embedding codes.
#'
#' The AEF Int8 decode `((x / 127.5)^2) * sign(x)`: per-value, nonlinear, sign-
#' preserving, mapping the code range `[-127, 127]` to ~`[-1, 1]`. Written in the
#' `g_*` vocabulary so it fuses onto the read as a garry map (pass to
#' [lazy_cog()] `dequant =`) -- on the device, not a separate decode pass.
#'
#' @param x Int8 codes (traced array or plain numeric).
#' @return The dequantized values, same shape as `x`.
#' @export
dequantize_aef <- function(x) {
  # sign(x) * (x / 127.5)^2, written branchless as xn * |xn| with xn = x / 127.5.
  # Divide first so the arithmetic runs in f32 (an Int8 source would overflow on
  # x * |x| before any promotion); the sign at x = 0 is irrelevant (magnitude 0).
  xn <- x / 127.5
  xn * abs(xn)
}
