# Reorder a garry extent for vaster calls.

garry orders extents (xmin, ymin, xmax, ymax); vaster expects (xmin,
xmax, ymin, ymax). This helper performs that reordering, so extents
cross the package boundary in one place.

## Usage

``` r
as_vaster_extent(x)
```

## Arguments

- x:

  A `GridSpec` or a length-4 garry-order extent.

## Value

Length-4 numeric in vaster order.
