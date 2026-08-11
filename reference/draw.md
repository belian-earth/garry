# Draw the pipeline of a lazy object.

Prints a terminal visual of the computation a lazy object will run,
before any reading or compute happens. A `LazyDataset` draws as its step
pipeline (source, mask, reduce, ...); a `LazyRaster` draws as its
intermediate representation (IR) tree, with structurally identical
sibling branches folded to a single `xN` branch so a large composite
graph stays readable.

## Usage

``` r
draw(x, ...)
```

## Arguments

- x:

  A `LazyRaster` or `LazyDataset`.

- ...:

  Unused.

## Value

`x`, invisibly.

## See also

[`preview()`](https://belian-earth.github.io/garry/reference/preview.md),
which plots the data rather than the pipeline;
[`plan_dot()`](https://belian-earth.github.io/garry/reference/plan_dot.md)
for a Graphviz rendering of the execution plan.
