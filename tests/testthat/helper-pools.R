# Split-pool boilerplate for tests: spin up the pools, tear them down
# when the calling test exits (withr::defer). Replaces the two-line
# garry_daemons(...) / on.exit(garry_daemons(0, 0, ...)) pattern at
# ~50 sites; tests that kill, rebuild or partially tear down pools
# keep explicit calls.
local_pools <- function(read, compute, ..., gdal_config = FALSE,
                        env = parent.frame()) {
  garry_daemons(read, compute, gdal_config = gdal_config, ...)
  withr::defer(garry_daemons(0, 0, gdal_config = FALSE), envir = env)
}

# Run `code` under a temporary chunk-size target (shared by the
# oracle/scan/chunk-invariance sweeps; was four inline copies).
.with_chunk_px <- function(px, code) {
  old <- options(garry.chunk_target_px = px)
  on.exit(options(old))
  force(code)
}
