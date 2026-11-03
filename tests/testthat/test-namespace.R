# R CMD check's undefined-global check as a test: a call to a stats or
# utils function that resolves only through the search path breaks
# wherever that package is not attached. Qualify it (`stats::setNames()`).

test_that("garry calls no default-package function unqualified", {
  ns <- asNamespace("garry")
  defaults <- c(
    "stats",
    "utils",
    "methods",
    "graphics",
    "grDevices",
    "datasets",
    "tools"
  )
  exported <- unique(unlist(lapply(defaults, getNamespaceExports)))
  # bound before the search path: locally, in garry, its imports or base
  resolves <- function(name, env) {
    while (!identical(env, globalenv()) && !identical(env, emptyenv())) {
      if (exists(name, envir = env, inherits = FALSE)) {
        return(TRUE)
      }
      env <- parent.env(env)
    }
    FALSE
  }
  offenders <- character(0)
  for (nm in ls(ns, all.names = TRUE)) {
    f <- get(nm, envir = ns)
    if (!is.function(f) || is.primitive(f)) {
      next
    }
    calls <- codetools::findGlobals(f, merge = FALSE)$functions
    calls <- calls[calls %in% exported]
    bad <- calls[!vapply(calls, resolves, logical(1), env = environment(f))]
    if (length(bad)) {
      offenders <- c(offenders, paste0(nm, ": ", bad))
    }
  }
  expect_identical(offenders, character(0))
})
