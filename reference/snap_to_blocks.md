# Snap requested chunk size to a multiple of native block size.

Snap requested chunk size to a multiple of native block size.

## Usage

``` r
snap_to_blocks(chunk_dim, block_dim)
```

## Arguments

- chunk_dim:

  Requested chunk size, integer length 2.

- block_dim:

  Native block size, integer length 2.

## Value

Integer length 2, block-aligned and at least one block.
