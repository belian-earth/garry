#' @include dataset.R gdal_adapter.R lazy_raster.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Multi-band COG read engine. garry's own read path is single-band per source
# (lazy_source(band=), BANDS=1 warp-on-read), so a geo-embedding stack (tens of
# bands in one file, e.g. Alpha Earth) reads slowly -- one open per band. For
# MULTI-BAND sources the read routes through cptkirk, whose Rust async-tiff
# reader opens each tile once and streams the band planes concurrently, then
# warps all bands in one pass into a native-dtype buffer (ck_warp_to_buffer).
# Single-band sources gain nothing (cptkirk's own guidance): use lazy_source() /
# lazy_dataset(). The dequant fuses on read.
#
# The buffer -> garry bridge is cptkirk's own trick: write the native BSQ bytes
# to a raw .bin and describe it with a VRTRawRasterBand VRT. GDAL reads that VRT
# with zero decode, and it is an ordinary GDAL path -- so lazy_source() consumes
# it directly, no GeoTIFF encode/decode round-trip, dtype stays native.
# ---------------------------------------------------------------------------

#' Read a multi-band COG into a lazy dataset via the cptkirk engine.
#'
#' Fetches a (multi-band) Cloud-Optimised GeoTIFF onto `grid` and returns a
#' `LazyDataset` with one band per selected source band, ready for garry's verbs
#' (`mask`, `reduce_over`, `band_project`, ...). Multi-band sources -- geo-
#' embedding stacks such as Alpha Earth -- route through
#' [cptkirk](https://belian-earth.github.io/cptkirk/): its async-tiff reader
#' opens each tile once and streams the band planes concurrently, then warps them
#' in one pass into a native-dtype buffer, far faster than per-band GDAL
#' `/vsicurl` for tens of bands. Single-band sources gain nothing from it; use
#' [lazy_source()] / [lazy_dataset()].
#'
#' The fetch is eager (the remote data is warped to a local grid-aligned buffer
#' once, so iterative analysis re-uses it); downstream compute stays lazy. The
#' source's nodata sentinel is carried through so those pixels read as NaN and
#' never reach the decode. `dequant` fuses a decode onto the read -- e.g.
#' [dequantize_aef()] -- on the device, not a separate pass.
#'
#' @param path COG path/URL (remote `http(s)://` or `/vsicurl/...`).
#' @param grid Target `GridSpec`.
#' @param bands Source band indices to read (default: all).
#' @param dequant Optional garry map `fn(x)` applied per band and fused at
#'   `collect()` (e.g. [dequantize_aef()]).
#' @param resampling GDAL resampling (default `"near"`, right for quantised
#'   codes).
#' @param names Optional band names (default `b<index>`).
#' @return A `LazyDataset`.
#' @export
read_cog <- function(path, grid, bands = NULL, dequant = NULL,
                     resampling = "near", names = NULL) {
  .assert_class(grid, GridSpec, "GridSpec")
  nb <- gdal_band_count(path)
  bands <- if (is.null(bands)) seq_len(nb) else as.integer(bands)
  if (length(bands) < 1L) cli::cli_abort("{.arg bands} selects no bands.")
  b <- .ck_warp_buffer(path, grid, bands, resampling)
  .cog_to_dataset(b$vrt, grid, bands, dequant, names, nodata = b$nodata)
}

# cptkirk fetch+warp of the selected bands onto `grid` into a native-dtype BSQ
# buffer, staged as a raw .bin + VRTRawRasterBand VRT for garry to read. The one
# cptkirk-dependent step. The source's own nodata sentinel (whatever it is --
# read from the source, not assumed) is used as the warp fill and returned so
# uncovered and nodata pixels alike read back as nodata.
.ck_warp_buffer <- function(path, grid, bands, resampling) {
  rlang::check_installed("cptkirk", reason = "for the multi-band COG read engine.")
  # Soft dependency: resolve at run time (no `cptkirk::` literal), so garry does
  # not declare cptkirk and CI does not pull in its Rust build. Formalise as an
  # Imports + Rust CI step once the read path stabilises.
  ck_warp_to_buffer <- getExportedValue("cptkirk", "ck_warp_to_buffer")
  nd  <- .src_nodata(path)                                   # numeric(0) if none
  res <- ck_warp_to_buffer(
    path, t_srs = grid@crs, te = as.numeric(grid@extent),
    ts = c(unname(grid@dims[["x"]]), unname(grid@dims[["y"]])),
    r = resampling, bands = bands,
    fill = if (length(nd)) nd else NULL)
  bin <- tempfile(fileext = ".bin")
  writeBin(res$data, bin)                                    # raw BSQ bytes
  ndv <- if (length(nd)) res$nodata else NULL
  list(vrt = .raw_bsq_vrt(bin, grid, res$dtype, res$nbands, ndv),
       nodata = if (length(nd)) as.numeric(res$nodata) else numeric(0))
}

# Wrap a local grid-aligned multi-band raster as a LazyDataset (garry-side, no
# network), optionally fusing a per-band dequant map. Reads at the source's
# NATIVE dtype (the grid fixes geometry, not the read type): an integer source
# carrying a `nodata` then promotes to f32 with the sentinel as NaN (D8), so the
# decode never sees it. Factored out so the wrapping is testable without cptkirk.
.cog_to_dataset <- function(local, grid, bands, dequant = NULL, names = NULL,
                            nodata = numeric(0)) {
  g   <- graph_new()
  nm  <- names %||% paste0("b", bands)
  nd  <- if (length(nodata)) as.numeric(nodata) else NULL
  sdt <- gdal_grid_spec(local, band = 1L)$grid@dtype        # source garry dtype
  rgrid <- if (!identical(sdt, grid@dtype)) .grid_retype(grid, sdt) else grid
  layers <- stats::setNames(lapply(seq_along(bands), function(i) {
    lr <- lazy_source(local, band = i, graph = g, grid = rgrid, nodata = nd)
    if (!is.null(dequant)) lr <- lazy_map(lr, fn = dequant, dtype = "f32")
    lr
  }), nm)
  as_dataset(layers)
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

# Describe a raw band-sequential (BSQ) buffer as a VRTRawRasterBand dataset on
# `grid`'s geometry, so GDAL (hence lazy_source) reads it with zero decode. Band
# b's plane starts at (b-1) * nx * ny * bytes; pixels are row-major within it.
# The VRT is written beside `bin` and references it as a relative sibling: GDAL
# refuses a VRTRawRasterBand pointing at an arbitrary absolute path unless the
# source is a sibling/child of the VRT (or GDAL_VRT_RAWRASTERBAND_ALLOWED_SOURCE
# is set), which we satisfy rather than loosening the global config.
.raw_bsq_vrt <- function(bin, grid, dtype, nbands, nodata = NULL) {
  nx <- unname(grid@dims[["x"]]); ny <- unname(grid@dims[["y"]])
  bytes <- .gdal_dtype_bytes(dtype)
  gt    <- paste(sprintf("%.16g", grid@transform), collapse = ", ")
  wkt   <- gdalraster::srs_to_wkt(grid@crs)
  plane <- as.numeric(nx) * as.numeric(ny) * bytes
  src   <- basename(bin)                                   # sibling of the VRT
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
  xml <- sprintf(paste0(
    '<VRTDataset rasterXSize="%d" rasterYSize="%d">',
    '\n  <SRS>%s</SRS>\n  <GeoTransform>%s</GeoTransform>\n%s\n</VRTDataset>'),
    nx, ny, wkt, gt, paste(bands_xml, collapse = "\n"))
  vrt <- file.path(dirname(bin),
                   paste0(tools::file_path_sans_ext(src), ".vrt"))
  writeLines(xml, vrt)
  vrt
}

#' Dequantize Alpha Earth (AEF) embedding codes.
#'
#' The AEF Int8 decode `((x / 127.5)^2) * sign(x)`: per-value, nonlinear, sign-
#' preserving, mapping the code range `[-127, 127]` to ~`[-1, 1]`. Written in the
#' `g_*` vocabulary so it fuses onto the read as a garry map (pass to
#' [read_cog()] `dequant =`) -- on the device, not a separate decode pass.
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
