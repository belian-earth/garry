#' @include dataset.R gdal_adapter.R lazy_raster.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Multi-band COG read engine. garry's own read path is single-band per source
# (lazy_source(band=), BANDS=1 warp-on-read), so a geo-embedding stack (tens of
# bands in one file, e.g. Alpha Earth) reads slowly -- one open per band. For
# MULTI-BAND sources the read routes through cptkirk, whose Rust async-tiff
# reader opens each tile once and streams the band planes concurrently, then
# hands the warp to GDAL. Single-band sources gain nothing (cptkirk's own
# guidance): use lazy_source() / lazy_dataset(). The dequant fuses on read.
# ---------------------------------------------------------------------------

#' Read a multi-band COG into a lazy dataset via the cptkirk engine.
#'
#' Fetches a (multi-band) Cloud-Optimised GeoTIFF onto `grid` and returns a
#' `LazyDataset` with one band per selected source band, ready for garry's verbs
#' (`mask`, `reduce_over`, `band_project`, ...). Multi-band sources -- geo-
#' embedding stacks such as Alpha Earth -- route through
#' [cptkirk](https://belian-earth.github.io/cptkirk/): its async-tiff reader
#' opens each tile once and streams the band planes concurrently, far faster than
#' per-band GDAL `/vsicurl` for tens of bands. Single-band sources gain nothing
#' from it; use [lazy_source()] / [lazy_dataset()].
#'
#' The fetch is eager (the remote data is warped to a local grid-aligned raster
#' once, so iterative analysis re-uses it); downstream compute stays lazy.
#' `dequant` fuses a decode onto the read -- e.g. [dequantize_aef()] -- on the
#' device, not a separate pass.
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
  local <- .ck_warp_local(path, grid, bands, resampling)
  .cog_to_dataset(local, grid, bands, dequant, names)
}

# cptkirk fetch+warp of the selected bands onto `grid` -> a local grid-aligned
# COG. The one cptkirk-dependent step; swap to cptkirk's raw "warp to bin"
# output (native dtype, band-sequential -- the gdal_warp_to_buffer contract)
# when available, to drop the GeoTIFF round-trip.
.ck_warp_local <- function(path, grid, bands, resampling) {
  rlang::check_installed("cptkirk", reason = "for the multi-band COG read engine.")
  # Soft dependency: resolve at run time (no `cptkirk::` literal), so garry does
  # not declare cptkirk and CI does not pull in its Rust build. Formalise as a
  # Suggests + Rust CI step once cptkirk (and its raw warp-to-bin) stabilise.
  ck_warp <- getExportedValue("cptkirk", "ck_warp")
  dst <- tempfile(fileext = ".tif")
  ck_warp(path, dst, t_srs = grid@crs, te = as.numeric(grid@extent),
          ts = c(unname(grid@dims[["x"]]), unname(grid@dims[["y"]])),
          r = resampling, bands = bands)
  dst
}

# Wrap a local grid-aligned multi-band raster as a LazyDataset (garry-side, no
# network), optionally fusing a per-band dequant map. Factored out so the
# wrapping is testable without cptkirk / a remote fetch.
.cog_to_dataset <- function(local, grid, bands, dequant = NULL, names = NULL) {
  g  <- graph_new()
  nm <- names %||% paste0("b", bands)
  layers <- stats::setNames(lapply(seq_along(bands), function(i) {
    lr <- lazy_source(local, band = i, graph = g, grid = grid)
    if (!is.null(dequant)) lr <- lazy_map(lr, fn = dequant, dtype = "f32")
    lr
  }), nm)
  as_dataset(layers)
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
  xn <- x / 127.5
  xn * xn * g_ifelse(x > 0, 1, g_ifelse(x < 0, -1, 0))
}
