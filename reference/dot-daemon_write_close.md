# Daemon task body: close every output the writer holds open.

Returns the close errors, named by output path (empty when all closed).

## Usage

``` r
.daemon_write_close()
```

## Value

`NULL`, invisibly.

## Details

Internal; daemons reach it through `asNamespace("garry")`.
