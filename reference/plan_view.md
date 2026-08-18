# Interactive Plan viewer.

Renders a `Plan` as an interactive DAG (an htmlwidget, via the suggested
visNetwork package): one node per stage, laid out left to right in
execution order on explicit topological levels. Stages are labelled by
what they compute, not just their scheduler kind: a compute stage is
classified by the IR nodes fused into it (`focal`, `scan`, `patch`,
`stack`, `map`, most informative first, the same vocabulary as
[`draw()`](https://belian-earth.github.io/garry/reference/draw.md)), and
reduce stages carry their reducer (`reduce\u00b7median`). When a
`LazyDataset` is passed, derived bands (`ds[["ndvi"]] <- ...`) are
recovered from the dataset's step record and the stage computing one is
labelled with the band name (`derive\u00b7ndvi`); the derivation is
bounded structurally at the first non-elementwise node, so it survives
subsetting (`ds["ndvi"]`). Hovering a stage shows its full op
composition and any recoverable metadata: acquisition dates on slice
sources and t-spans on composites (from stack ordering and grid labels),
the band a stage computes, source file and band, and op parameters
(reducer and axis, focal radius, scan direction): plus members, halo,
device, and output grid; clicking highlights its neighbours; the sink
stage is drawn with a heavy border. Where
[`plan_dot()`](https://belian-earth.github.io/garry/reference/plan_dot.md)
emits static Graphviz text, `plan_view()` is the exploratory sibling:
watch the plan change shape as a pipeline is composed.

## Usage

``` r
plan_view(
  x,
  level_separation = NULL,
  node_spacing = 90,
  height = "600px",
  width = "100%"
)
```

## Arguments

- x:

  A `Plan` from
  [`plan_lazy()`](https://belian-earth.github.io/garry/reference/plan_lazy.md),
  a `LazyRaster`, a `LazyDataset` (its bands are assembled along the
  band axis first, as in
  [`collect()`](https://belian-earth.github.io/garry/reference/collect.md)),
  or a named list of `LazyRaster`s.

- level_separation:

  Horizontal distance between topological levels, in pixels. `NULL`
  (default) adapts to the graph's shape: wide plans (many sources, few
  levels) get a landscape aspect so the left-to-right flow stays
  legible, floored by label clearance and capped for deep plans. Pass a
  number to override.

- node_spacing:

  Distance between nodes within a level, in pixels: vertical, since
  levels run left to right. The tall stretch of a wide plan (e.g. one
  source per time slice) is this times the widest level's node count;
  lower it to compress.

- height, width:

  Widget size, as CSS units.

## Value

A `visNetwork` htmlwidget.

## See also

[`plan_dot()`](https://belian-earth.github.io/garry/reference/plan_dot.md)
for DOT text,
[`draw()`](https://belian-earth.github.io/garry/reference/draw.md) for
pixels.

## Examples

``` r
if (FALSE) { # \dontrun{
lr <- lazy_source("cube.tif")
plan_view(focal(lr * 2, radius = 1L, fn = g_mean))
} # }
```
