# Reorder a garry extent for vaster calls.

garry: (xmin, ymin, xmax, ymax); vaster: (xmin, xmax, ymin, ymax). This
helper is the ONLY sanctioned reorder point (decision D1).

## Usage

``` r
as_vaster_extent(x)
```

## Arguments

- x:

  A `GridSpec` or a length-4 garry-order extent.

## Value

Length-4 numeric in vaster order.
