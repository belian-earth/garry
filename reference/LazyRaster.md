# Lazy raster array (single band stack).

Users obtain one via
[`lazy_source()`](https://belian-earth.github.io/garry/reference/lazy_source.md),
[`lazy_cog()`](https://belian-earth.github.io/garry/reference/lazy_cog.md),
or
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
band access, and materialise it with
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md);
the constructor itself is rarely called directly.

## Usage

``` r
LazyRaster(graph = Graph(), node_id = integer(0), grid = GridSpec())
```

## Arguments

- graph:

  The shared intermediate representation (IR) `Graph`.

- node_id:

  Integer id of this raster's node.

- grid:

  Cached `GridSpec` for fast dim/crs access.

## Value

A `LazyRaster`.
