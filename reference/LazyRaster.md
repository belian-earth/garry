# Lazy raster array.

Lazy raster array.

## Usage

``` r
LazyRaster(graph = Graph(), node_id = integer(0), grid = GridSpec())
```

## Arguments

- graph:

  The shared IR `Graph`.

- node_id:

  Integer id of this raster's node.

- grid:

  Cached `GridSpec` for fast dim/crs access.

## Value

A `LazyRaster`.
