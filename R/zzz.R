.onLoad <- function(libname, pkgname) {
  # Required for S7 methods registered on base/external generics
  # (arithmetic Ops, print) to dispatch from an installed package.
  S7::methods_register()

  # garry's mosaic layer uses GDAL's GTI (GDAL Tile Index) driver, added in
  # GDAL 3.9. Warn loudly on an older GDAL: lazy_dataset() / lazy_cog() will
  # fail to open "GTI:" sources otherwise. Fires on any load (incl. `::` use).
  vn <- tryCatch(gdal_version_num(), error = function(e) NA_integer_)
  if (!is.na(vn) && vn < 3090000L) {
    cli::cli_inform(c(
      "x" = "garry needs GDAL >= 3.9 for the GTI mosaic driver behind {.fn lazy_dataset} / {.fn lazy_cog}.",
      "i" = "Found {gdal_version_str()}; those readers will fail."
    ))
  }
}

.onAttach <- function(libname, pkgname) {
  msg <- tryCatch(gdal_version_str(), error = function(e) NULL)
  # cli styling, but through packageStartupMessage so suppressPackageStartupMessages() works.
  if (!is.null(msg)) packageStartupMessage(cli::format_inline("{.pkg garry}: {msg}"))
}
