# Daemon task body: warm this daemon's XLA/PJRT client.

Runs one trivial jitted kernel so the first real compute task does not
pay the cold client initialisation. Internal (exported only so mirai
daemons can address it via `::`).

## Usage

``` r
.gd_warm()
```
