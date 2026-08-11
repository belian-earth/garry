# Create a GTI tile index layer from a source table.

`entries` must have a `location` column (paths / VSI URLs) and either a
`geom` column (WKT polygons in `crs`) or `xmin`/`ymin`/`xmax`/`ymax`
columns. All other columns become index fields (numeric -\> Real,
otherwise String); a `datetime` column enables per-slice FILTERs and
SORT_FIELD ordering.

## Usage

``` r
gti_index_create(entries, path, crs, layer = "index")
```

## Arguments

- entries:

  data.frame describing one tile per row.

- path:

  Index path (".gti.gpkg" or ".gti.fgb" recommended).

- crs:

  CRS of the index geometries (any GDAL-interpretable form).

- layer:

  Layer name.

## Value

`path`, invisibly.

## See also

[`gti_open_options()`](https://belian-earth.github.io/garry/reference/gti_open_options.md)
