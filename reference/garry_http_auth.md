# Authenticate remote reads under a URL prefix.

Registers an HTTP header, typically `Authorization: Bearer <token>`,
that GDAL sends with every request to a URL starting with `prefix`. It
applies on the host and on every garry daemon, including pools that
[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)
starts later. The header is scoped to the prefix, so a token for one
provider never reaches another. Setting `GDAL_HTTP_HEADERS` in the
environment instead sends it to every host garry reads from.

## Usage

``` r
garry_http_auth(prefix, header, refresh = 1800)
```

## Arguments

- prefix:

  URL prefix, e.g. `"https://catalog.maap.eo.esa.int/"`. A bare
  `http(s)://` prefix is registered in its `/vsicurl/` form, which is
  how garry opens remote sources; other GDAL virtual file system
  prefixes are taken as given.

- header:

  A header line (several lines joined by `"\r\n"`), a function returning
  one, or `NULL` to remove the prefix's header.

- refresh:

  Seconds before a function `header` is called again. Ignored for a
  fixed header.

## Value

Invisibly, the registered prefixes.

## Details

For short-lived tokens, pass a function as `header`. It is called now,
and again when a
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
starts once `refresh` seconds have passed; a changed header is pushed to
every daemon. GDAL keeps the header a file was opened with until every
handle on that file closes, so a change also closes garry's cached
dataset handles in every process. Tokens refresh between runs, not
during one: choose `refresh` so that a token outlives `refresh` plus
your longest run.

Header values are never printed, and they do not appear in task logs or
[`garry_task_report()`](https://belian-earth.github.io/garry/reference/garry_task_report.md).

## See also

[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md),
[`garry_gdal_config()`](https://belian-earth.github.io/garry/reference/garry_gdal_config.md)

## Examples

``` r
if (FALSE) { # \dontrun{
# ESA MAAP: exchange an offline token for a 10 h access token
garry_http_auth(
  "https://catalog.maap.eo.esa.int/",
  function() paste("Authorization: Bearer", maap_access_token()),
  refresh = 3600
)
} # }
```
