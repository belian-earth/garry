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

# cptkirk reads raw URLs through its own async-tiff/obstore HTTP path, so strip
# the GDAL /vsicurl/ prefix that stac_sources() adds for the GDAL reader. A
# pre-signed Azure blob URL keeps its SAS query -- cptkirk detects it
# (azure_sas_opt) and reads it; an UNSIGNED Azure URL falls back to the Azure
# credential chain (IMDS) and fails off-Azure, so pass signed URLs (as
# stac_query() + rstac::items_sign() produce).
.ck_url <- function(p) sub("^/vsicurl/", "", as.character(p))

.ck_register <- function(srcs, bands, resampling, nodata, grid) {
  spec <- list(srcs = .ck_url(srcs), bands = bands, resampling = resampling,
               nodata = if (length(nodata)) as.numeric(nodata) else numeric(0),
               te = as.numeric(grid@extent),
               ts = c(unname(grid@dims[["x"]]), unname(grid@dims[["y"]])),
               crs = grid@crs)
  key <- rlang::hash(spec)                  # identical reads dedup to one fetch
  .ck_registry[[key]] <- spec
  paste0("CK:", key)
}

.ck_lookup <- function(rpath) .ck_registry[[sub("^CK:", "", rpath)]]

#' Read multi-band COGs into a lazy dataset via the cptkirk engine.
#'
#' **Use `lazy_cog` for multi-band Cloud-Optimised GeoTIFFs** -- files with many
#' bands in one COG, such as geo-embedding stacks (Alpha Earth's 64-band tiles).
#' It reads through [cptkirk](https://belian-earth.github.io/cptkirk/), whose
#' async-tiff reader opens each tile ONCE and streams all its band planes
#' concurrently -- far faster than GDAL's one-open-per-band for tens of bands.
#'
#' **For single-band-per-asset time series (HLS, Sentinel-2, Landsat), use
#' [lazy_dataset()] instead.** cptkirk's only lever is intra-file band
#' concurrency, which single-band files do not have, so `lazy_cog` there is no
#' faster than GDAL (and its per-file opens make it slower on many small reads).
#'
#' The API mirrors [lazy_dataset()] so the two are interchangeable in use: both
#' build the same `LazyDataset` and support the same `mask()` / `reduce_over()` /
#' `collect()` verbs; only the read engine differs.
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
#' NaN. `lazy_cog` only reads: value transforms (a decode such as
#' [dequantize_aef()], scaling, ...) go downstream as maps
#' (`lazy_map(ds, fn = ...)`), which garry fuses onto the read at `collect()`.
#'
#' @param sources A STAC `doc_items` (from [stac_query()], optionally filtered)
#'   or a `stac_sources()`-style dataframe for the time-series form; or a COG path
#'   / character vector of tiles (remote `http(s)://` or `/vsicurl/`) for the
#'   single form.
#' @param grid Target `GridSpec`.
#' @param assets Asset names to read (dataframe form; a band each).
#' @param bands Source band indices (single-COG form; default: all).
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
lazy_cog <- function(sources, grid, assets = NULL, bands = NULL,
                     resampling = "near", names = NULL, mask_asset = NULL,
                     granularity = "day", sort_field = "datetime",
                     nodata = NULL, lon = NULL) {
  rlang::check_installed("cptkirk",
                         reason = "for lazy_cog(), the cptkirk read engine.")
  .assert_class(grid, GridSpec, "GridSpec")
  # A STAC `doc_items` (post query/filter) becomes the sources table internally;
  # a data.frame is a manual/non-STAC time series; a character path is a single
  # (multi-band) COG or a tile mosaic.
  if (inherits(sources, "doc_items"))
    sources <- stac_sources(sources, assets = unique(c(assets, mask_asset)))
  if (is.data.frame(sources))
    return(.lazy_cog_series(sources, grid, assets, mask_asset, granularity,
                            sort_field, nodata, resampling, lon))
  .lazy_cog_single(as.character(sources), grid, bands, resampling, names)
}

# Single (multi-band) COG or tile mosaic -> one time slice, a band per selected
# source band. Reads at the source's NATIVE dtype (the grid fixes geometry, not
# the read type): an integer source carrying a `nodata` then promotes to f32 with
# the sentinel as NaN (D8), so a downstream decode never sees it.
.lazy_cog_single <- function(path, grid, bands, resampling, names) {
  m <- .ck_meta(path[[1L]])
  bands <- if (is.null(bands)) seq_len(m$n_bands) else as.integer(bands)
  if (length(bands) < 1L) cli::cli_abort("{.arg bands} selects no bands.")
  ckpath <- .ck_register(path, bands, resampling, m$nodata, grid)
  rgrid <- if (!identical(m$dtype, grid@dtype)) .grid_retype(grid, m$dtype) else grid
  ndv <- if (length(m$nodata)) m$nodata else NULL
  g   <- graph_new()
  nm  <- names %||% paste0("b", bands)
  layers <- stats::setNames(lapply(seq_along(bands), function(i)
    lazy_source(ckpath, band = i, graph = g, grid = rgrid, nodata = ndv)), nm)
  as_dataset(layers)
}

# Time-series form: mirror lazy_dataset(). A band per named asset; a per-slice CK:
# source over that asset-slice's items (cptkirk mosaics them), instead of a GTI +
# GDAL warp-on-read. mask()/reduce_over()/collect() are engine-agnostic dataset
# ops, so they work unchanged; .ck_resolve coalesces per asset-slice source set.
.lazy_cog_series <- function(sources, grid, assets, mask_asset, granularity,
                             sort_field, nodata, resampling, lon) {
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
    m       <- .ck_meta(a_rows$location[[1L]])
    nd      <- resolve_nodata(a, m$nodata)
    rgrid   <- if (!identical(m$dtype, grid@dtype)) .grid_retype(grid, m$dtype) else grid
    ndv     <- if (length(nd)) as.numeric(nd) else NULL
    slices  <- sort(unique(a_rows$slice))
    layers  <- lapply(slices, function(sl) {
      items  <- a_rows$location[a_rows$slice == sl][order(
        a_rows$datetime[a_rows$slice == sl])]
      ckpath <- .ck_register(items, 1L, resampling, nd, grid)
      lazy_source(ckpath, band = 1L, graph = g, grid = rgrid, nodata = ndv)
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

# Collect-time pre-pass: fetch every "CK:" source set and rewrite the source-node
# paths to a staged grid-aligned raster the executors read as an ordinary GDAL
# source. Single-item source sets that share (grid, bands, resampling) are fetched
# TOGETHER through ONE cptkirk pool (ck_batch) -- the win for many-slice time
# series, where per-set sequential fetches would serialise the network. Lone sets
# and spatial mosaics keep ck_warp_to_buffer's no-encode buffer path. Returns the
# (mutated) plan and a staging root to unlink after collect, or root = NULL when
# there is nothing to resolve.
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

  ukeys <- unique(keys)
  specs <- stats::setNames(lapply(ukeys, .ck_lookup), ukeys)
  if (any(vapply(specs, is.null, TRUE)))
    cli::cli_abort("Unresolved {.fn lazy_cog} source.")
  staged <- new.env(parent = emptyenv())            # ukey -> staged path

  # Single-band source sets (one band per file, each a 1+ tile mosaic) go through
  # ONE ck_batch pool per grid/resampling signature -- every tile of every set is
  # fetched concurrently, the saturation win for many-slice time series. Mosaics
  # are then assembled locally (gdalbuildvrt overlay). Multi-band single files
  # (geo-embedding stacks) keep ck_warp_to_buffer's no-encode buffer path.
  single <- ukeys[vapply(ukeys, function(k) length(specs[[k]]$bands) == 1L, TRUE)]
  if (length(single)) {
    sig <- vapply(single, function(k) {
      s <- specs[[k]]; rlang::hash(list(s$te, s$ts, s$crs, s$resampling, s$bands))
    }, "")
    for (grp in unique(sig)) {
      members <- single[sig == grp]
      if (length(members) > 1L)                 # >1 set: one pool. Lone -> buffer.
        .ck_batch_mosaic(members, specs, root, staged)
    }
  }
  for (k in ukeys) if (is.null(staged[[k]]))    # lone single-band sets + multi-band
    staged[[k]] <- .ck_fetch(specs[[k]], root)

  for (i in seq_along(ids)) {
    n <- graph_get(g, ids[[i]])
    n@path <- staged[[keys[[i]]]]
    graph_replace(g, ids[[i]], n)
  }
  list(plan = p, root = root)
}

# Fetch a group of single-band source sets (each a 1+ tile mosaic) sharing an
# AOI/resampling through ONE cptkirk pool. ck_batch(stack = FALSE) returns one
# warped file PER TILE, so every tile of every set streams through one io budget
# concurrently. Then mosaic each set's tiles locally -- a gdalbuildvrt overlay,
# no network -- and record the staged path. Each source's own nodata is read from
# its header by cptkirk; garry masks on the node's nodata regardless.
.ck_batch_mosaic <- function(members, specs, root, staged) {
  s0  <- specs[[members[[1L]]]]
  src <- lapply(members, function(k) specs[[k]]$srcs)       # per set: its tiles
  dst <- unlist(lapply(seq_along(members), function(i)
    file.path(root, sprintf("cb_%s_%02d.tif",
                            sub("^CK:", "", members[[i]]), seq_along(src[[i]])))))
  out <- cptkirk::ck_batch(
    src = src, dst = dst, stack = FALSE,
    t_srs = s0$crs, te = s0$te, ts = s0$ts,
    bands = if (length(s0$bands)) s0$bands else NULL,
    r = s0$resampling, io_concurrency = 32L)
  for (i in seq_along(members)) {
    files <- as.character(out[[i]])                          # tiles, datetime order
    staged[[members[[i]]]] <- if (length(files) == 1L) files[[1L]]
      else gdal_mosaic_vrt(
        file.path(root, paste0("mos_", sub("^CK:", "", members[[i]]), ".vrt")),
        files)
  }
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

# Source metadata (band count, garry dtype, nodata sentinel) via cptkirk's native
# header read. Deliberately NOT GDAL: a plain https path without /vsicurl makes
# GDAL try to pull the whole remote COG (a 2.7 GB AEF tile hangs), and cptkirk
# reads the raw URL its async-tiff way in one fast call -- the same URL it fetches
# with. nodata comes back numeric(0) when the source declares none. All bands are
# assumed to share one sentinel (the case for geo-embedding stacks).
.ck_meta <- function(src) {
  info <- cptkirk::cog_info(.ck_url(src))
  nd <- info$nodata
  list(n_bands = info$n_bands,
       dtype   = .gdal_dtype_map[[info$dtype]] %||% info$dtype,
       nodata  = if (is.null(nd) || (length(nd) == 1L && is.na(nd))) numeric(0)
                 else as.numeric(nd))
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
