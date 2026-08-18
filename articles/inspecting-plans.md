# Inspecting plans with plan_view()

Every garry pipeline is a plan before it is a computation: verbs add
nodes to a compute graph, the planner fuses those nodes into schedulable
stages, and nothing reads or computes until
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md).
[`plan_view()`](https://belian-earth.github.io/garry/reference/plan_view.md)
renders that plan as an interactive DAG, so you can see exactly what an
execution will do, and check it, before paying for it. It accepts
anything
[`plan_lazy()`](https://belian-earth.github.io/garry/reference/plan_lazy.md)
accepts: a `LazyRaster`, a `LazyDataset`, a named list of rasters, or a
ready-made `Plan`.

``` r

library(garry)
#> garry: GDAL 3.11.4 "Eganville", released 2025/09/04
```

## A first plan

A single-raster chain: double the band (a map), smooth it (a focal), and
reduce over space. Note there is no separate node for the `* 2`: the
planner fuses elementwise maps into their consumer, so it rides inside
the focal stage, named in its label (`focal + map`). The spatial
reduction is different: reducing over `x` and `y` needs values from
every chunk, so it becomes a two-stage barrier. Each chunk emits a small
partial (for a mean, a sum and a count), and a combine stage folds the
partials into the final scalar.

``` r

tif <- file.path(tempdir(), "band.tif")
ds <- gdalraster::create("GTiff", tif, 60, 40, 1, "Float32",
                         return_obj = TRUE)
ds$setGeoTransform(c(500000, 10, 0, 4600000, 0, -10))
#> [1] TRUE
ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
#> [1] TRUE
ds$write(1, 0, 0, 60, 40, as.numeric(seq_len(60 * 40)))
ds$close()

lr <- lazy_source(tif, name = "band")
plan_view(reduce_over(focal(lr * 2, radius = 1L, fn = g_mean),
                      "mean", c("x", "y")),
          height = "320px")
```

Click a node to highlight its neighbours, hover for detail, and drag or
zoom with the ink controls.

## A composite pipeline

The same view over a realistic dataset pipeline: a cloud-masked median
composite with a derived band, built from a small local mock of a STAC
collection (three acquisition dates, two value assets, one QA asset).

``` r

mk <- function(nm, m) {
  f <- file.path(tempdir(), nm)
  ds <- gdalraster::create("GTiff", f, 20, 16, 1, "Float32",
                           return_obj = TRUE)
  ds$setGeoTransform(c(0, 10, 0, 160, 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  ds$write(1, 0, 0, 20, 16, as.numeric(t(m)))
  ds$close()
  f
}
bbox <- gdalraster::transform_bounds(c(0, 0, 200, 160),
                                     "EPSG:3857", "EPSG:4326")
dates <- c("2023-01-05T01:00:00Z", "2023-01-15T01:00:00Z",
           "2023-02-05T01:00:00Z")
items <- list(features = lapply(1:3, function(i) {
  v <- outer(1:16, 1:20, function(r, c) r * 100 + c) + (i - 1) * 1000
  q <- matrix((seq_len(16 * 20) + i) %% 4, 16, 20)
  list(id = sprintf("item-%d", i), bbox = as.list(bbox),
       properties = list(datetime = dates[[i]], `eo:cloud_cover` = 10),
       assets = list(
         B04   = list(href = mk(sprintf("ip-B04-%d.tif", i), v)),
         B08   = list(href = mk(sprintf("ip-B08-%d.tif", i), v * 2)),
         Fmask = list(href = mk(sprintf("ip-Q-%d.tif", i), q))))
}))
```

The pipeline is the shape of the README example: per-band temporal
median, then NDVI as a derived band (masking joins in the next section).

``` r

src  <- stac_sources(items, assets = c("B04", "B08", "Fmask"))
grid <- gdal_grid_spec(src$location[src$asset == "B04"][[1]])$grid

composite <- lazy_dataset(src, grid, assets = c("B04", "B08")) |>
  reduce_over("median", over = "t", nan_rm = TRUE)
composite[["ndvi"]] <- (composite[["B08"]] - composite[["B04"]]) /
  (composite[["B08"]] + composite[["B04"]])

plan_view(composite, height = "420px")
```

Three things are worth noticing. Each band’s whole chain (the time stack
and the median) fuses into a single amber reduce stage, so the diagram
shows what will actually be scheduled, not the verbs you typed. The
`derive·ndvi` stage receives solid edges only from the bands its
arithmetic reads; the composites also land in the output directly, as
dashed pass-through edges. And the white output node states the written
product: dimensions, dtype, and every band it will contain.

## Fusion in action

Now add the cloud mask. Each per-slice mask map reads its value slice
and the shared QA slice, and those shared QA reads connect the two band
chains into one fusable subgraph. The planner responds by fusing the
entire composite, masking, medians, NDVI and assembly alike, into a
single stage: one compiled kernel per chunk.

``` r

masked <- lazy_dataset(src, grid, assets = c("B04", "B08"),
                       mask_asset = "Fmask") |>
  mask(where = qa_bits(0:1)) |>
  reduce_over("median", over = "t", nan_rm = TRUE)
masked[["ndvi"]] <- (masked[["B08"]] - masked[["B04"]]) /
  (masked[["B08"]] + masked[["B04"]])

plan_view(masked, height = "420px")
```

The stage label lists everything that fused into it, and every member
keeps its meaning: the masks
[`mask()`](https://belian-earth.github.io/garry/reference/mask.md)
created are named as masks, the reducers carry their op, the derivation
its band. This is the diagram earning its keep: the structure you reason
about (bands, masks, a derived index) and the structure the machine
executes (one kernel) are both real, and
[`plan_view()`](https://belian-earth.github.io/garry/reference/plan_view.md)
shows which one you will pay for.

One thing keeps the collapse in check: focal work. Morphological mask
cleanup (`mask(open = , dilate = )`) is focal, and the planner keeps
focal members in narrow stages of their own so halo reads stay cheap.
Add it and the plan splits back apart, into per-slice mask stages and
per-band composite stages; that is the shape the README example shows.

## Reading the graph

Nodes are stages, coloured by family and shaped by what they compute. An
edge means the target consumes the source’s chunks; dashed edges mark
writes into the output rather than compute dependencies. The sink stage
carries a heavy border.

| mark | family | meaning |
|----|----|----|
| green cylinder | IO | `source`: a windowed, halo-padded GDAL read |
| teal box / ellipse | elementwise | `map` / `stack`: fused band algebra and axis stacking |
| teal square | elementwise | `derive`: a named dataset band (`ds[["ndvi"]] <- ...`) |
| crimson circle | elementwise | `mask`: the predicate and apply maps [`mask()`](https://belian-earth.github.io/garry/reference/mask.md) creates |
| crimson hexagon / star / diamond | spatial | `focal` / `patch` (model inference) / `warp` |
| amber dot / triangle / inverted triangle | temporal and reductions | `scan` / `reduce partial` / `reduce combine` |
| white box | output | the written product: dims, dtype, bands |

A fused stage is labelled by its full composition
(`reduce·median + stack + 2 map`) and identified by its most informative
member, so a stage that stacks, masks, and reduces reads as the reduce.
Reducers carry their op name; derived bands carry the band name.

## What hover shows

Tooltips surface the metadata the plan still carries:

- acquisition dates on slice sources, and the full time span on
  composite stages, recovered from stack ordering and grid labels;
- the asset or band a source reads (`asset: B04`), set by
  [`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md),
  or via `lazy_source(name = )`;
- the band a stage computes, and for a derivation, the bands it reads;
- op parameters: reducer and axis (`median over t, nan_rm`), focal
  radius and boundary, scan axis and direction, read scale/offset;
- the stage’s fused IR members, halo, device, and output grid.

## Tuning the layout

The layout packs each topological level and adapts the horizontal level
separation to the graph’s shape, so wide plans keep a landscape aspect.
Two knobs override it:

``` r

# more horizontal air, tighter rows
plan_view(composite, level_separation = 1000, node_spacing = 60)
```

`level_separation` is the horizontal distance between levels;
`node_spacing` is the vertical pitch within a level.

## Related tools

[`draw()`](https://belian-earth.github.io/garry/reference/draw.md)
renders the same pipeline as glyphs in the terminal, and
[`print()`](https://rdrr.io/r/base/print.html) summarises a dataset’s
steps.
[`plan_dot()`](https://belian-earth.github.io/garry/reference/plan_dot.md)
emits the plan as Graphviz DOT text for documents.
[`plan_lazy()`](https://belian-earth.github.io/garry/reference/plan_lazy.md)
returns the `Plan` object itself, and `collect(x, plan_only = TRUE)` is
its execution-facing twin. All of them now accept a `LazyDataset`
directly.
