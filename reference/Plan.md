# A physical execution plan: stages in dependency order.

A physical execution plan: stages in dependency order.

## Usage

``` r
Plan(stages = list(), sink = integer(0), sinks = integer(0), graph = Graph())
```

## Arguments

- stages:

  List of `Stage`, indexed by stage id.

- sink:

  Id of the terminal stage.

- sinks:

  Named integer vector of requested sink NODE ids for multi-export plans
  (empty for single-sink plans).

- graph:

  The IR `Graph` the plan was built from.

## Value

A `Plan`.
