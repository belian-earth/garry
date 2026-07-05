# Stub source: a LazyRaster over a fake path with a fixed 100x100
# EPSG:4326 grid. Keeps IR/planner tests independent of GDAL IO (the
# real lazy_source() reads metadata from disk as of Phase 4a).

lazy_source_stub <- function(path, band = 1L, graph = graph_new(),
                             nodata = NULL, dtype = "f32") {
  grid <- GridSpec(
    crs       = "EPSG:4326",
    transform = c(0, 1, 0, 0, 0, -1),
    extent    = c(0, -100, 100, 0),
    dims      = c(100L, 100L),
    dtype     = dtype
  )
  nodata <- if (is.null(nodata)) numeric(0) else as.numeric(nodata)
  if (length(nodata) == 1L && garry:::.dtype_family(dtype) != "float")
    grid <- garry:::.grid_retype(grid, "f32")
  id <- graph_add(
    graph, SourceNode,
    parents = integer(0), grid = grid,
    path = path, band = as.integer(band), nodata = nodata
  )
  LazyRaster(graph = graph, node_id = id, grid = grid)
}
