.onLoad <- function(libname, pkgname) {
  # Required for S7 methods registered on base/external generics
  # (arithmetic Ops, print) to dispatch from an installed package.
  S7::methods_register()
}
