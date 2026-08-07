# Output of the composition pass. Holds a composed R function assembled from its members; ready for `anvl::jit()` at execution time.

Output of the composition pass. Holds a composed R function assembled
from its members; ready for
[`anvl::jit()`](https://r-xla.github.io/anvl/reference/jit.html) at
execution time.

## Usage

``` r
FusedNode(
  id = integer(0),
  parents = integer(0),
  grid = GridSpec(),
  fn = function() NULL,
  members = integer(0),
  halo = integer(0)
)
```

## Arguments

- id:

  Integer node id (assigned by
  [`graph_add()`](https://belian-earth.github.io/garry/reference/graph_add.md)).

- parents:

  Integer ids of parent nodes (may be empty).

- grid:

  Output `GridSpec` of this node.

- fn:

  Composed stage function.

- members:

  Ids of the absorbed nodes.

- halo:

  Combined halo radius of the members.

## Value

A `FusedNode`.
