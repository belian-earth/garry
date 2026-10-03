# Grid extent, resolution and CRS

Read the georeferencing of a grid, a lazy raster or a lazy dataset.

## Usage

``` r
grid_bbox(x)

grid_res(x)

grid_crs(x)
```

## Arguments

- x:

  A `GridSpec`, `LazyRaster` or `LazyDataset`.

## Value

`grid_bbox()`: a named numeric `c(xmin, ymin, xmax, ymax)`.
`grid_res()`: a named numeric `c(x, y)` of positive cell sizes.
`grid_crs()`: the CRS as a string.

## Examples

``` r
g <- grid_spec(c(0, 0, 100, 50), res = 10, crs = "EPSG:3857")
grid_bbox(g)
#> xmin ymin xmax ymax 
#>    0    0  100   50 
grid_res(g)
#>  x  y 
#> 10 10 
grid_crs(g)
#> [1] "PROJCS[\"WGS 84 / Pseudo-Mercator\",GEOGCS[\"WGS 84\",DATUM[\"WGS_1984\",SPHEROID[\"WGS 84\",6378137,298.257223563,AUTHORITY[\"EPSG\",\"7030\"]],AUTHORITY[\"EPSG\",\"6326\"]],PRIMEM[\"Greenwich\",0,AUTHORITY[\"EPSG\",\"8901\"]],UNIT[\"degree\",0.0174532925199433,AUTHORITY[\"EPSG\",\"9122\"]],AUTHORITY[\"EPSG\",\"4326\"]],PROJECTION[\"Mercator_1SP\"],PARAMETER[\"central_meridian\",0],PARAMETER[\"scale_factor\",1],PARAMETER[\"false_easting\",0],PARAMETER[\"false_northing\",0],UNIT[\"metre\",1,AUTHORITY[\"EPSG\",\"9001\"]],AXIS[\"Easting\",EAST],AXIS[\"Northing\",NORTH],EXTENSION[\"PROJ4\",\"+proj=merc +a=6378137 +b=6378137 +lat_ts=0 +lon_0=0 +x_0=0 +y_0=0 +k=1 +units=m +nadgrids=@null +wktext +no_defs\"],AUTHORITY[\"EPSG\",\"3857\"]]"
```
