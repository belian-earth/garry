# Promote two dtypes for a binary operation.

The promotion rules:

- float dominates: float op int/uint/pred keeps the float type;

- within a family the wider type wins;

- pred promotes to the other operand;

- signed op unsigned promotes to a signed type wide enough for both (u64
  has no signed container, so it promotes to f64, following NumPy);

- `divide = TRUE` forces a float result: 32-bit-or-narrower integer
  inputs give f32, 64-bit integer inputs give f64.

## Usage

``` r
dtype_promote(a, b, divide = FALSE)
```

## Arguments

- a, b:

  dtype strings from the garry vocabulary.

- divide:

  Is the operation a division?

## Value

The promoted dtype string.
