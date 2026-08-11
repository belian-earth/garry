# Read a garry policy option.

Looks up `getOption("garry.<name>")`, falling back to the package
default. Unknown option names error.

## Usage

``` r
garry_opt(name)
```

## Arguments

- name:

  Option name without the `garry.` prefix.

## Value

The option value.

## See also

[`garry_options()`](https://belian-earth.github.io/garry/reference/garry_options.md)
