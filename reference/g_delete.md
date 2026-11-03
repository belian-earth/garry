# Free an AnvlArray's memory now.

The memory goes once any execution reading it has finished, with no gc,
and any later use of `x` is an error.

## Usage

``` r
g_delete(x)
```

## Arguments

- x:

  `AnvlArray`.

## Value

`NULL`, invisibly.
