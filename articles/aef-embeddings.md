# Reading Alpha Earth embeddings

[Alpha Earth
Foundations](https://deepmind.google/blog/alphaearth-foundations-helps-map-our-planet-in-unprecedented-detail/)
(AEF) by Google is published by [Source
Cooperative](https://source.coop/tge-labs/aef). This dataset is a
collection of annual geospatial embeddings stored as **64-band Int8
Cloud-Optimised GeoTIFFs**: each band is one dimension of a learned
embedding, quantised to a signed byte and decoded with a nonlinear,
sign-preserving transform, `((x / 127.5)^2) * sign(x)`.

A multi-band file is just another source: give
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
the path and it builds one band per file band, named from the file’s
band descriptions (`A00` .. `A63` here). Each band is its own source, so
at
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
the reads fan out band-by-band across the reader pool, with many
connections issuing range requests concurrently, which is what makes a
64-band remote read fast. This vignette reads one tile, decodes it and
resamples it to 30 m on the read, and renders three arbitrary bands as a
false-colour composite.

## Read and dequantise

``` r

library(garry)

# One AEF annual tile (Source Cooperative, public, no auth). UTM 36S, ~10 m.
tile <- paste0("https://data.source.coop/tge-labs/aef/v1/annual/2021/36S/",
               "xekh5rjs4wg6wb9b4-0000000000-0000000000.tiff")

# the analysis grid: the tile's own footprint at 30 m
grid <- grid_from_src(tile, 30)

embeddings <- lazy_dataset(tile, grid, resampling = "average",
                           decode = dequantize_aef)

embeddings
#> ── <LazyDataset> ──────────────────────────────────────────────
#>   bands  A00 A01 A02 A03 A04 A05 A06 A07 ... (+56)
#>   time   1 slice
#>   grid   2732 x 2731 • f32
#>   crs    EPSG:32736
#>   graph  128 nodes • lazy
#>   ℹ plan_draw(x) to see the pipeline
```

[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
records a lazy 64-band dataset; nothing is fetched yet (the construction
costs one metadata probe, however many bands the file carries).
`decode = dequantize_aef` decodes every 10 m code through a lookup table
before the average, so each 30 m value is the mean of the decoded
embeddings, the order a nonlinear decode needs.

## Collect three bands and plot

Pick three arbitrary embedding dimensions: the band-axis subset means
only those three are ever read or computed.
[`preview()`](https://belian-earth.github.io/garry/reference/preview.md)
reads them on the full 30 m grid and decimates them for the plot. A file
source is not pinned to a grid, so it cannot use the tile’s overviews;
[`preview()`](https://belian-earth.github.io/garry/reference/preview.md)
says so in a message.

``` r

garry_daemons()
# cube <- collect(embeddings[c("A09", "A10", "A11")])

preview(embeddings[c("A09", "A10", "A11")], bands=c(2,1,3))   # False-colour composite
```

![plot of chunk
aef-plot](https://raw.githubusercontent.com/belian-earth/garry/main/vignettes/figure/aef-plot-1.png)

plot of chunk aef-plot

Neighbouring pixels of similar land cover carry similar embeddings, so
the false-colour image segments the landscape into coherent regions: the
structure the embeddings encode. But three bands show three of
sixty-four dimensions. The clustering below uses all of them.

## Cluster the full embedding space

An unsupervised k-means over the 64-dimensional embedding vectors
segments the landscape without a single training label. The pattern is
fit-small, predict-lazily, with both halves reading one local cube:

**Materialise once.** Both halves below read all 64 bands, so decode the
tile a single time into a local cube and work from that. This is the one
expensive step, and it is explicit: the remote fetch and the dequant
happen once, and everything after reads local pixels.

``` r

cube <- materialise(embeddings)   # pass dir= to keep it beyond the session
```

**Fit.** k-means needs pixels in R, but not all 7.5 million of them:
100k scattered ones place five centroids perfectly well.
[`extract_points()`](https://belian-earth.github.io/garry/reference/extract_points.md)
reads just those, straight out of the local cube: GDAL reads only the
rows holding points, here nearly all of them, but from local disk rather
than the network.

Points are a [wk](https://paleolimbot.github.io/wk/) `xy` vector
carrying their own CRS, so they are placed on the grid explicitly rather
than by assumption
([`wk::as_xy()`](https://paleolimbot.github.io/wk/reference/xy.html)
converts points from sf, terra or a data frame).

``` r

set.seed(42)
n   <- 1e5
bb  <- grid_bbox(grid)
pts <- wk::xy(
  stats::runif(n, bb[["xmin"]], bb[["xmax"]]),
  stats::runif(n, bb[["ymin"]], bb[["ymax"]]),
  crs = grid_crs(grid)
)

px <- extract_points(cube, pts)              # (100000, 64)
dim(px)
#> [1] 100000     64
px <- px[stats::complete.cases(px), ]
km <- kmeans(px, centers = 5)
km$size
#> [1] 12303 31500 24144 22116  9937
```

The same call is how a model gets its training table off any garry
pipeline: give it the GEDI shots, the field plots or the labelled points
instead of random ones. `interp = "bilinear"` interpolates the four
surrounding cell centres for continuous data measured off-grid, and
`krnl_dim` reads a window around each point instead of a single cell.

**Assign.** Every 30 m pixel goes to its nearest centroid:
`argmax_k (x . c_k - |c_k|^2 / 2)`, and `x . c_k` is a linear
combination of bands: the
[`band_project()`](https://belian-earth.github.io/garry/reference/band_project.md)
reducer from the [PCA
article](https://belian-earth.github.io/garry/articles/hls-harmonized-pca.md).
The argmax is expressible in the same public vocabulary, so the WHOLE
assignment runs inside the graph: a custom band reducer composes five
projections with a comparison chain, and
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
returns the finished cluster map. This is ordinary user code – garry’s
shipped verbs are built from exactly these pieces, with no privileged
access to the engine.

``` r

nearest_center <- function(centers) {
  ct   <- unname(as.matrix(centers))            # k x band
  half <- rowSums(ct^2) / 2
  proj <- lapply(seq_len(nrow(ct)), function(k) band_project(ct[k, ]))
  function(x, dims) {
    s1   <- proj[[1]](x, dims) - half[[1]]      # score against centre 1
    best <- s1
    cl   <- s1 * 0 + 1                          # current best label
    for (k in 2:nrow(ct)) {
      sk   <- proj[[k]](x, dims) - half[[k]]
      hit  <- sk > best
      cl   <- g_ifelse(hit, k, cl)
      best <- g_ifelse(hit, sk, best)
    }
    g_ifelse(g_is_nodata(s1), NaN, cl)          # nodata stays nodata
  }
}

clusters <- reduce_over(stack_bands(cube),
                        nearest_center(km$centers), over = "band")
clmap <- collect(clusters)

garry_daemons(0, 0)
```

One fused kernel reads the 64-band cube once, computes every projection
and the argmax per pixel, and only the finished single-band cluster map
ever reaches R. (Want the raw scores instead? Stack plain
[`band_project()`](https://belian-earth.github.io/garry/reference/band_project.md)
reducers with `lazy_stack(along = "band")` and take
[`max.col()`](https://rdrr.io/r/base/maxCol.html) host-side: same
digital numbers.)

The k-means prediction can also stream straight to disk. Note the
`dtype` and `overview_resampling` arguments: COG overviews default to
“average”, and an averaged class label is meaningless, so categorical
outputs want “nearest”:

``` r

write_tif(
  clusters,
  "km-aef.tif",
  dtype = "i16",
  cog = TRUE,
  overview_resampling = "nearest"
)
```

And the final k-means map:

``` r

preview(
  clmap,
  col = c("#E41A1C", "#377EB8", "#4DAF4A", "#984EA3", "#FF7F00")
)
```

![plot of chunk
km-plot](https://raw.githubusercontent.com/belian-earth/garry/main/vignettes/figure/km-plot-1.png)

plot of chunk km-plot

Five clusters, no labels, and the landscape decomposes into its
structure: the dendritic drainage network, the river corridor and
settlement strip, and the textured forest mosaic each claim their own
class. The same dequantised dataset feeds any downstream verb the same
way: a band-axis PCA, a similarity search, or a classifier fit on the
collected array.
