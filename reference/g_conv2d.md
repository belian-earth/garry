# 2D convolution over a (C, H, W) chunk.

Torch-layout convolution for in-graph model inference: `x` is a
channels-first `(C_in, H, W)` array, `w` a
`(C_out, C_in/groups, kH, kW)` kernel, `bias` an optional length-`C_out`
vector. `stride`, `padding` (symmetric), and `dilation` are scalars or
length-2 `(y, x)`. `groups` gives grouped/depthwise convolution. Weights
and bias are plain R arrays; traced they enter the kernel as constants
uploaded once at compile.

## Usage

``` r
g_conv2d(
  x,
  w,
  bias = NULL,
  stride = 1L,
  padding = 0L,
  dilation = 1L,
  groups = 1L
)
```

## Arguments

- x:

  `(C_in, H, W)` array (traced or plain).

- w:

  `(C_out, C_in/groups, kH, kW)` numeric array.

- bias:

  Optional length-`C_out` numeric.

- stride, padding, dilation:

  Scalar or length-2 integers.

- groups:

  Feature group count.

## Value

`(C_out, H_out, W_out)` array.

## Details

The plain-R branch is an im2col matmul: correct at any size, meant for
tests, not throughput.
