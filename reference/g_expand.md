# Insert a broadcast axis at an arbitrary position.

The rank-general sibling of
[`g_rep_t()`](https://belian-earth.github.io/garry/reference/g_rep_t.md):
expands `x` with a new axis of `n` copies at position `axis`, so a
reduced statistic broadcasts back against the array it came from (base R
arrays do not broadcast, so the untraced oracle needs the copies
materialised; traced, this is a free `broadcast_to`).

## Usage

``` r
g_expand(x, axis, n)
```

## Arguments

- x:

  Array (traced or plain).

- axis:

  1-based position of the new axis in the output.

- n:

  Length of the new axis.

## Value

Array of rank `length(dim(x)) + 1`.
