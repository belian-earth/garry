# Read a garry policy option.

Looks up `getOption("garry.<name>")`, falling back to the package
default. Unknown names error: constants must be registered in
`.garry_defaults` so defaults live in one place.

## Usage

``` r
garry_opt(name)
```

## Arguments

- name:

  Option name without the `garry.` prefix.

## Value

The option value.
