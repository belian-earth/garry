# Daemon task body: close every output the writer holds open.

Internal; daemons reach it through `asNamespace("garry")`.

## Usage

``` r
.daemon_write_close()
```

## Value

The close failures, named by output path (empty when all closed).
