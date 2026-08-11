# Is `dtype` a member of garry's dtype vocabulary?

The valid dtype strings are `"f32"`, `"f64"`, `"i8"`, `"i16"`, `"i32"`,
`"i64"`, `"u8"`, `"u16"`, `"u32"`, `"u64"`, and `"pred"` (a
boolean/predicate type).

## Usage

``` r
dtype_valid(dtype)
```

## Arguments

- dtype:

  A dtype string, e.g. `"f32"`.

## Value

`TRUE` or `FALSE`.
