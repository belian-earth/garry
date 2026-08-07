# Broadcast arrays to a common shape (compute vocabulary).

numpy-style broadcasting for the `g_*` vocabulary: the hook for per-band
constants in a band reducer – multiply a `(band, y, x)` cube by a
`(band, 1, 1)` loading vector before summing over band (a linear
projection; see
[`band_project()`](https://belian-earth.github.io/garry/reference/band_project.md)).
anvl requires operands broadcast explicitly. Traces to anvl when given
traced arrays, else broadcasts plain-R arrays (same rank).

## Usage

``` r
g_broadcast_arrays(...)
```

## Arguments

- ...:

  Two or more arrays (traced or plain).

## Value

A list of the inputs broadcast to their common shape.
