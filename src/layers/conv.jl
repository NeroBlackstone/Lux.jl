@doc doc"""
    Conv(k::NTuple{N,Integer}, (in_chs => out_chs)::Pair{<:Integer,<:Integer},
         activation=identity; init_weight=glorot_uniform, init_bias=zeros32, stride=1,
         pad=0, dilation=1, groups=1, use_bias=true, allow_fast_activation=true)

Standard convolutional layer.

Image data should be stored in WHCN order (width, height, channels, batch). In other words,
a `100 x 100` RGB image would be a `100 x 100 x 3 x 1` array, and a batch of 50 would be a
`100 x 100 x 3 x 50` array. This has `N = 2` spatial dimensions, and needs a kernel size
like `(5, 5)`, a 2-tuple of integers. To take convolutions along `N` feature dimensions,
this layer expects as input an array with `ndims(x) == N + 2`, where
`size(x, N + 1) == in_chs` is the number of input channels, and `size(x, ndims(x))` is the
number of observations in a batch.

!!! warning

    Frameworks like [`Pytorch`](https://pytorch.org/docs/stable/generated/torch.nn.Conv2d.html#torch.nn.Conv2d)
    perform cross-correlation in their convolution layers

## Arguments

  - `k`: Tuple of integers specifying the size of the convolutional kernel. Eg, for 2D
         convolutions `length(k) == 2`
  - `in_chs`: Number of input channels
  - `out_chs`: Number of input and output channels
  - `activation`: Activation Function

## Keyword Arguments

  - `init_weight`: Controls the initialization of the weight parameter
  - `init_bias`: Controls the initialization of the bias parameter

  - `stride`: Should each be either single integer, or a tuple with `N` integers
  - `dilation`: Should each be either single integer, or a tuple with `N` integers
  - `pad`: Specifies the number of elements added to the borders of the data array. It can
           be
    
      + a single integer for equal padding all around,
      + a tuple of `N` integers, to apply the same padding at begin/end of each spatial
        dimension,
      + a tuple of `2*N` integers, for asymmetric padding, or
      + the singleton `SamePad()`, to calculate padding such that
        `size(output,d) == size(x,d) / stride` (possibly rounded) for each spatial
        dimension.
      + Periodic padding can achieved by pre-empting the layer with a
        `WrappedFunction(x -> NNlib.circular_pad(x, N_pad; dims=pad_dims))`

  - `groups`: Expected to be an `Int`. It specifies the number of groups to divide a
              convolution into (set `groups = in_chs` for Depthwise Convolutions). `in_chs`
              and `out_chs` must be divisible by `groups`.
  - `use_bias`: Trainable bias can be disabled entirely by setting this to `false`.
  - `allow_fast_activation`: If `true`, then certain activations can be approximated with
    a faster version. The new activation function will be given by
    `NNlib.fast_act(activation)`

## Inputs

  - `x`: Data satisfying `ndims(x) == N + 2 && size(x, N - 1) == in_chs`, i.e.
         `size(x) = (I_N, ..., I_1, C_in, N)`

## Returns

  - Output of the convolution `y` of size `(O_N, ..., O_1, C_out, N)` where

```math
O_i = \left\lfloor\frac{I_i + p_i + p_{(i + N) \% |p|} - d_i \times (k_i - 1)}{s_i} + 1\right\rfloor
```

  - Empty `NamedTuple()`

## Parameters

  - `weight`: Convolution kernel
  - `bias`: Bias (present if `use_bias=true`)
"""
@concrete struct Conv{N, use_bias, M} <: AbstractExplicitLayer
    activation
    in_chs::Int
    out_chs::Int
    kernel_size::NTuple{N, Int}
    stride::NTuple{N, Int}
    pad::NTuple{M, Int}
    dilation::NTuple{N, Int}
    groups::Int
    init_weight
    init_bias
end

function Conv(k::NTuple{N, Integer}, ch::Pair{<:Integer, <:Integer}; activation=identity,
        init_weight=glorot_uniform, init_bias=zeros32, stride=1, pad=0, dilation=1,
        groups=1, use_bias::Bool=true, allow_fast_activation::Bool=true) where {N}
    stride = _expand(Val(N), stride)
    dilation = _expand(Val(N), dilation)
    pad = _calc_padding(pad, k, dilation, stride)
    activation = allow_fast_activation ? NNlib.fast_act(activation) : activation

    return Conv{N, use_bias, length(pad)}(activation, first(ch), last(ch), k, stride,
        pad, dilation, groups, init_weight, init_bias)
end

function initialparameters(rng::AbstractRNG, c::Conv{N, use_bias}) where {N, use_bias}
    weight = _convfilter(
        rng, c.kernel_size, c.in_chs => c.out_chs; init=c.init_weight, groups=c.groups)
    if use_bias
        return (; weight, bias=c.init_bias(rng, ntuple(_ -> 1, N)..., c.out_chs, 1))
    else
        return (; weight)
    end
end

function parameterlength(c::Conv{N, use_bias}) where {N, use_bias}
    return prod(c.kernel_size) * c.in_chs * c.out_chs ÷ c.groups +
           (use_bias ? c.out_chs : 0)
end

@inline function (c::Conv)(x::AbstractArray, ps, st::NamedTuple)
    y = match_eltype(c, ps, st, x)
    cdims = DenseConvDims(y, ps.weight; c.stride, padding=c.pad, c.dilation, c.groups)
    return (
        fused_conv_bias_activation(
            c.activation, ps.weight, y, _getproperty(ps, Val(:bias)), cdims),
        st)
end

function Base.show(io::IO, l::Conv)
    print(io, "Conv(", l.kernel_size)
    print(io, ", ", l.in_chs, " => ", l.out_chs)
    _print_conv_opt(io, l)
    return print(io, ")")
end

function _print_conv_opt(io::IO, l::Conv{N, use_bias}) where {N, use_bias}
    l.activation == identity || print(io, ", ", l.activation)
    all(==(0), l.pad) || print(io, ", pad=", __tuple_string(l.pad))
    all(==(1), l.stride) || print(io, ", stride=", __tuple_string(l.stride))
    all(==(1), l.dilation) || print(io, ", dilation=", __tuple_string(l.dilation))
    (l.groups == 1) || print(io, ", groups=", l.groups)
    (use_bias == false) && print(io, ", use_bias=false")
    return nothing
end

@doc doc"""
    MaxPool(window::NTuple; pad=0, stride=window)

Max pooling layer, which replaces all pixels in a block of size `window` with the maximum
value.

# Arguments

  - `window`: Tuple of integers specifying the size of the window. Eg, for 2D pooling
              `length(window) == 2`

## Keyword Arguments

  - `stride`: Should each be either single integer, or a tuple with `N` integers

  - `pad`: Specifies the number of elements added to the borders of the data array. It can
           be
    
      + a single integer for equal padding all around,
      + a tuple of `N` integers, to apply the same padding at begin/end of each spatial
        dimension,
      + a tuple of `2*N` integers, for asymmetric padding, or
      + the singleton `SamePad()`, to calculate padding such that
        `size(output,d) == size(x,d) / stride` (possibly rounded) for each spatial
        dimension.

## Inputs

  - `x`: Data satisfying `ndims(x) == N + 2`, i.e. `size(x) = (I_N, ..., I_1, C, N)`

## Returns

  - Output of the pooling `y` of size `(O_N, ..., O_1, C, N)` where

```math
  O_i = \left\lfloor\frac{I_i + p_i + p_{(i + N) \% |p|} - d_i \times (k_i - 1)}{s_i} + 1\right\rfloor
```

  - Empty `NamedTuple()`

See also [`Conv`](@ref), [`MeanPool`](@ref), [`GlobalMaxPool`](@ref),
[`AdaptiveMaxPool`](@ref)
"""
struct MaxPool{N, M} <: AbstractExplicitLayer
    k::NTuple{N, Int}
    pad::NTuple{M, Int}
    stride::NTuple{N, Int}
end

function MaxPool(k::NTuple{N, Integer}; pad=0, stride=k) where {N}
    stride = _expand(Val(N), stride)
    pad = _calc_padding(pad, k, 1, stride)
    return MaxPool{N, length(pad)}(k, pad, stride)
end

function (m::MaxPool{N, M})(x, ps, st::NamedTuple) where {N, M}
    pdims = PoolDims(x, m.k; padding=m.pad, stride=m.stride)
    return maxpool(x, pdims), st
end

function Base.show(io::IO, m::MaxPool)
    print(io, "MaxPool(", m.k)
    all(==(0), m.pad) || print(io, ", pad=", __tuple_string(m.pad))
    m.stride == m.k || print(io, ", stride=", __tuple_string(m.stride))
    return print(io, ")")
end

@doc doc"""
    MeanPool(window::NTuple; pad=0, stride=window)

Mean pooling layer, which replaces all pixels in a block of size `window` with the mean
value.

# Arguments

  - `window`: Tuple of integers specifying the size of the window. Eg, for 2D pooling
              `length(window) == 2`

## Keyword Arguments

  - `stride`: Should each be either single integer, or a tuple with `N` integers

  - `pad`: Specifies the number of elements added to the borders of the data array. It can
           be
    
      + a single integer for equal padding all around,
      + a tuple of `N` integers, to apply the same padding at begin/end of each spatial
        dimension,
      + a tuple of `2*N` integers, for asymmetric padding, or
      + the singleton `SamePad()`, to calculate padding such that
        `size(output,d) == size(x,d) / stride` (possibly rounded) for each spatial
        dimension.

## Inputs

  - `x`: Data satisfying `ndims(x) == N + 2`, i.e. `size(x) = (I_N, ..., I_1, C, N)`

## Returns

  - Output of the pooling `y` of size `(O_N, ..., O_1, C, N)` where

```math
  O_i = \left\lfloor\frac{I_i + p_i + p_{(i + N) \% |p|} - d_i \times (k_i - 1)}{s_i} + 1\right\rfloor
```

  - Empty `NamedTuple()`

See also [`Conv`](@ref), [`MaxPool`](@ref), [`GlobalMeanPool`](@ref),
[`AdaptiveMeanPool`](@ref)
"""
struct MeanPool{N, M} <: AbstractExplicitLayer
    k::NTuple{N, Int}
    pad::NTuple{M, Int}
    stride::NTuple{N, Int}
end

function MeanPool(k::NTuple{N, Integer}; pad=0, stride=k) where {N}
    stride = _expand(Val(N), stride)
    pad = _calc_padding(pad, k, 1, stride)
    return MeanPool{N, length(pad)}(k, pad, stride)
end

function (m::MeanPool{N, M})(x, ps, st::NamedTuple) where {N, M}
    pdims = PoolDims(x, m.k; padding=m.pad, stride=m.stride)
    return meanpool(x, pdims), st
end

function Base.show(io::IO, m::MeanPool)
    print(io, "MeanPool(", m.k)
    all(==(0), m.pad) || print(io, ", pad=", __tuple_string(m.pad))
    m.stride == m.k || print(io, ", stride=", __tuple_string(m.stride))
    return print(io, ")")
end

"""
    Upsample(mode = :nearest; [scale, size])
    Upsample(scale, mode = :nearest)

Upsampling Layer.

## Layer Construction

### Option 1

  - `mode`: Set to `:nearest`, `:linear`, `:bilinear` or `:trilinear`

Exactly one of two keywords must be specified:

  - If `scale` is a number, this applies to all but the last two dimensions (channel and
    batch) of the input.  It may also be a tuple, to control dimensions individually.
  - Alternatively, keyword `size` accepts a tuple, to directly specify the leading
    dimensions of the output.

### Option 2

  - If `scale` is a number, this applies to all but the last two dimensions (channel and
    batch) of the input.  It may also be a tuple, to control dimensions individually.
  - `mode`: Set to `:nearest`, `:bilinear` or `:trilinear`

Currently supported upsampling `mode`s and corresponding NNlib's methods are:

  - `:nearest` -> `NNlib.upsample_nearest`
  - `:bilinear` -> `NNlib.upsample_bilinear`
  - `:trilinear` -> `NNlib.upsample_trilinear`

## Inputs

  - `x`: For the input dimensions look into the documentation for the corresponding `NNlib`
    function

      + As a rule of thumb, `:nearest` should work with arrays of arbitrary dimensions
      + `:bilinear` works with 4D Arrays
      + `:trilinear` works with 5D Arrays

## Returns

  - Upsampled Input of size `size` or of size `(I_1 x scale[1], ..., I_N x scale[N], C, N)`
  - Empty `NamedTuple()`
"""
@concrete struct Upsample{mode} <: AbstractExplicitLayer
    scale
    size
end

function Upsample(mode::Symbol=:nearest; scale=nothing, size=nothing)
    mode in [:nearest, :bilinear, :trilinear] ||
        throw(ArgumentError("mode=:$mode is not supported."))
    if !xor(isnothing(scale), isnothing(size))
        throw(ArgumentError("Either scale or size should be specified (but not both)."))
    end
    return Upsample{mode}(scale, size)
end

Upsample(scale, mode::Symbol=:nearest) = Upsample(mode; scale)

for interp in (:nearest, :bilinear, :trilinear)
    interp_func = Symbol(:upsample_, interp)
    @eval begin
        function (m::Upsample{$(Meta.quot(interp))})(x::AbstractArray, ps, st::NamedTuple)
            return NNlib.$(interp_func)(x, m.scale), st
        end
        function (m::Upsample{$(Meta.quot(interp)), Nothing})(
                x::AbstractArray, ps, st::NamedTuple)
            return NNlib.$(interp_func)(x; m.size), st
        end
    end
end

function (m::Upsample{:nearest, Int})(x::AbstractArray, ps, st::NamedTuple)
    return NNlib.upsample_nearest(x, ntuple(i -> m.scale, ndims(x) - 2)), st
end

function Base.show(io::IO, u::Upsample{mode}) where {mode}
    print(io, "Upsample(")
    print(io, ":", mode)
    u.scale !== nothing && print(io, ", scale = $(u.scale)")
    u.size !== nothing && print(io, ", size = $(u.size)")
    return print(io, ")")
end

"""
    GlobalMaxPool()

Global Max Pooling layer. Transforms (w,h,c,b)-shaped input into (1,1,c,b)-shaped output,
by performing max pooling on the complete (w,h)-shaped feature maps.

## Inputs

  - `x`: Data satisfying `ndims(x) > 2`, i.e. `size(x) = (I_N, ..., I_1, C, N)`

## Returns

  - Output of the pooling `y` of size `(1, ..., 1, C, N)`
  - Empty `NamedTuple()`

See also [`MaxPool`](@ref), [`AdaptiveMaxPool`](@ref), [`GlobalMeanPool`](@ref)
"""
struct GlobalMaxPool <: AbstractExplicitLayer end

function (g::GlobalMaxPool)(x, ps, st::NamedTuple)
    return maxpool(x, PoolDims(x, size(x)[1:(end - 2)])), st
end

"""
    GlobalMeanPool()

Global Mean Pooling layer. Transforms (w,h,c,b)-shaped input into (1,1,c,b)-shaped output,
by performing mean pooling on the complete (w,h)-shaped feature maps.

## Inputs

  - `x`: Data satisfying `ndims(x) > 2`, i.e. `size(x) = (I_N, ..., I_1, C, N)`

## Returns

  - Output of the pooling `y` of size `(1, ..., 1, C, N)`
  - Empty `NamedTuple()`

See also [`MeanPool`](@ref), [`AdaptiveMeanPool`](@ref), [`GlobalMaxPool`](@ref)
"""
struct GlobalMeanPool <: AbstractExplicitLayer end

function (g::GlobalMeanPool)(x, ps, st::NamedTuple)
    return meanpool(x, PoolDims(x, size(x)[1:(end - 2)])), st
end

"""
    AdaptiveMaxPool(out::NTuple)

Adaptive Max Pooling layer. Calculates the necessary window size such that its output has
`size(y)[1:N] == out`.

## Arguments

  - `out`: Size of the first `N` dimensions for the output

## Inputs

  - `x`: Expects as input an array with `ndims(x) == N+2`, i.e. channel and batch
    dimensions, after the `N` feature dimensions, where `N = length(out)`.

## Returns

  - Output of size `(out..., C, N)`
  - Empty `NamedTuple()`

See also [`MaxPool`](@ref), [`AdaptiveMeanPool`](@ref).
"""
struct AdaptiveMaxPool{S, O} <: AbstractExplicitLayer
    out::NTuple{O, Int}
    AdaptiveMaxPool(out::NTuple{O, Int}) where {O} = new{O + 2, O}(out)
end

function (a::AdaptiveMaxPool{S})(x::AbstractArray{T, S}, ps, st::NamedTuple) where {S, T}
    pdims = compute_adaptive_pooling_dims(x, a.out)
    return maxpool(x, pdims), st
end

function Base.show(io::IO, a::AdaptiveMaxPool)
    return print(io, "AdaptiveMaxPool(", a.out, ")")
end

"""
    AdaptiveMeanPool(out::NTuple)

Adaptive Mean Pooling layer. Calculates the necessary window size such that its output has
`size(y)[1:N] == out`.

## Arguments

  - `out`: Size of the first `N` dimensions for the output

## Inputs

  - `x`: Expects as input an array with `ndims(x) == N+2`, i.e. channel and batch
    dimensions, after the `N` feature dimensions, where `N = length(out)`.

## Returns

  - Output of size `(out..., C, N)`
  - Empty `NamedTuple()`

See also [`MeanPool`](@ref), [`AdaptiveMaxPool`](@ref).
"""
struct AdaptiveMeanPool{S, O} <: AbstractExplicitLayer
    out::NTuple{O, Int}
    AdaptiveMeanPool(out::NTuple{O, Int}) where {O} = new{O + 2, O}(out)
end

function (a::AdaptiveMeanPool{S})(x::AbstractArray{T, S}, ps, st::NamedTuple) where {S, T}
    return meanpool(x, compute_adaptive_pooling_dims(x, a.out)), st
end

function Base.show(io::IO, a::AdaptiveMeanPool)
    return print(io, "AdaptiveMeanPool(", a.out, ")")
end

"""
    PixelShuffle(r::Int)

Pixel shuffling layer with upscale factor `r`. Usually used for generating higher
resolution images while upscaling them.

See `NNlib.pixel_shuffle` for more details.

PixelShuffle is not a Layer, rather it returns a [`WrappedFunction`](@ref) with the
function set to `Base.Fix2(pixel_shuffle, r)`

## Arguments

  - `r`: Upscale factor

## Inputs

  - `x`: For 4D-arrays representing N images, the operation converts input
    `size(x) == (W, H, r² x C, N)` to output of size `(r x W, r x H, C, N)`. For
    D-dimensional data, it expects `ndims(x) == D + 2` with channel and batch dimensions, and
    divides the number of channels by `rᴰ`.

## Returns

  - Output of size `(r x W, r x H, C, N)` for 4D-arrays, and `(r x W, r x H, ..., C, N)`
    for D-dimensional data, where `D = ndims(x) - 2`
"""
PixelShuffle(r::Int) = WrappedFunction{:direct_call}(Base.Fix2(pixel_shuffle, r))

@doc doc"""
    CrossCor(k::NTuple{N,Integer}, (in_chs => out_chs)::Pair{<:Integer,<:Integer},
             activation=identity; init_weight=glorot_uniform, init_bias=zeros32, stride=1,
             pad=0, dilation=1, use_bias=true, allow_fast_activation=true)

Cross Correlation layer.

Image data should be stored in WHCN order (width, height, channels, batch). In other words,
a `100 x 100` RGB image would be a `100 x 100 x 3 x 1` array, and a batch of 50 would be a
`100 x 100 x 3 x 50` array. This has `N = 2` spatial dimensions, and needs a kernel size
like `(5, 5)`, a 2-tuple of integers. To take convolutions along `N` feature dimensions,
this layer expects as input an array with `ndims(x) == N + 2`, where
`size(x, N + 1) == in_chs` is the number of input channels, and `size(x, ndims(x))` is the
number of observations in a batch.

## Arguments

  - `k`: Tuple of integers specifying the size of the convolutional kernel. Eg, for 2D
         convolutions `length(k) == 2`
  - `in_chs`: Number of input channels
  - `out_chs`: Number of input and output channels
  - `activation`: Activation Function

## Keyword Arguments

  - `init_weight`: Controls the initialization of the weight parameter
  - `init_bias`: Controls the initialization of the bias parameter

  - `stride`: Should each be either single integer, or a tuple with `N` integers
  - `dilation`: Should each be either single integer, or a tuple with `N` integers
  - `pad`: Specifies the number of elements added to the borders of the data array. It can
           be

      + a single integer for equal padding all around,
      + a tuple of `N` integers, to apply the same padding at begin/end of each spatial
        dimension,
      + a tuple of `2*N` integers, for asymmetric padding, or
      + the singleton `SamePad()`, to calculate padding such that
        `size(output,d) == size(x,d) / stride` (possibly rounded) for each spatial
        dimension.

  - `use_bias`: Trainable bias can be disabled entirely by setting this to `false`.
  - `allow_fast_activation`: If `true`, then certain activations can be approximated with
    a faster version. The new activation function will be given by
    `NNlib.fast_act(activation)`

## Inputs

  - `x`: Data satisfying `ndims(x) == N + 2 && size(x, N - 1) == in_chs`, i.e.
         `size(x) = (I_N, ..., I_1, C_in, N)`

## Returns

  - Output of the convolution `y` of size `(O_N, ..., O_1, C_out, N)` where

```math
O_i = \left\lfloor\frac{I_i + p_i + p_{(i + N) \% |p|} - d_i \times (k_i - 1)}{s_i} + 1\right\rfloor
```

  - Empty `NamedTuple()`

## Parameters

  - `weight`: Convolution kernel
  - `bias`: Bias (present if `use_bias=true`)
"""
@concrete struct CrossCor{N, use_bias, M} <: AbstractExplicitLayer
    activation
    in_chs::Int
    out_chs::Int
    kernel_size::NTuple{N, Int}
    stride::NTuple{N, Int}
    pad::NTuple{M, Int}
    dilation::NTuple{N, Int}
    init_weight
    init_bias
end

function CrossCor(
        k::NTuple{N, Integer}, ch::Pair{<:Integer, <:Integer}; activation=identity,
        init_weight=glorot_uniform, init_bias=zeros32, stride=1, pad=0, dilation=1,
        use_bias::Bool=true, allow_fast_activation::Bool=true) where {N}
    stride = _expand(Val(N), stride)
    dilation = _expand(Val(N), dilation)
    pad = _calc_padding(pad, k, dilation, stride)
    activation = allow_fast_activation ? NNlib.fast_act(activation) : activation

    return CrossCor{N, use_bias, length(pad)}(
        activation, first(ch), last(ch), k, stride, pad, dilation, init_weight, init_bias)
end

function initialparameters(rng::AbstractRNG, c::CrossCor{N, use_bias}) where {N, use_bias}
    weight = _convfilter(rng, c.kernel_size, c.in_chs => c.out_chs; init=c.init_weight)
    if use_bias
        return (; weight, bias=c.init_bias(rng, ntuple(_ -> 1, N)..., c.out_chs, 1))
    else
        return (; weight)
    end
end

function parameterlength(c::CrossCor{N, use_bias}) where {N, use_bias}
    return prod(c.kernel_size) * c.in_chs * c.out_chs + (use_bias ? c.out_chs : 0)
end

@inline function (c::CrossCor)(x::AbstractArray, ps, st::NamedTuple)
    y = match_eltype(c, ps, st, x)
    cdims = DenseConvDims(
        DenseConvDims(y, ps.weight; c.stride, padding=c.pad, c.dilation); F=true)
    return (
        fused_conv_bias_activation(
            c.activation, ps.weight, y, _getproperty(ps, Val(:bias)), cdims),
        st)
end

function Base.show(io::IO, l::CrossCor)
    print(io, "CrossCor(", l.kernel_size)
    print(io, ", ", l.in_chs, " => ", l.out_chs)
    _print_crosscor_opt(io, l)
    return print(io, ")")
end

function _print_crosscor_opt(io::IO, l::CrossCor{N, use_bias}) where {N, use_bias}
    l.activation == identity || print(io, ", ", l.activation)
    all(==(0), l.pad) || print(io, ", pad=", __tuple_string(l.pad))
    all(==(1), l.stride) || print(io, ", stride=", __tuple_string(l.stride))
    all(==(1), l.dilation) || print(io, ", dilation=", __tuple_string(l.dilation))
    (use_bias == false) && print(io, ", use_bias=false")
    return nothing
end

@doc doc"""
    ConvTranspose(k::NTuple{N,Integer}, (in_chs => out_chs)::Pair{<:Integer,<:Integer},
                  activation=identity; init_weight=glorot_uniform, init_bias=zeros32,
                  stride=1, pad=0, dilation=1, groups=1, use_bias=true, 
                  allow_fast_activation=true)

Standard convolutional transpose layer.

## Arguments

  - `k`: Tuple of integers specifying the size of the convolutional kernel. Eg, for 2D
         convolutions `length(k) == 2`
  - `in_chs`: Number of input channels
  - `out_chs`: Number of input and output channels
  - `activation`: Activation Function

## Keyword Arguments

  - `init_weight`: Controls the initialization of the weight parameter
  - `init_bias`: Controls the initialization of the bias parameter

  - `stride`: Should each be either single integer, or a tuple with `N` integers
  - `dilation`: Should each be either single integer, or a tuple with `N` integers
  - `pad`: Specifies the number of elements added to the borders of the data array. It can
           be
    
      + a single integer for equal padding all around,
      + a tuple of `N` integers, to apply the same padding at begin/end of each spatial
        dimension,
      + a tuple of `2*N` integers, for asymmetric padding, or
      + the singleton `SamePad()`, to calculate padding such that
        `size(output,d) == size(x,d) * stride` (possibly rounded) for each spatial
        dimension.

  - `groups`: Expected to be an `Int`. It specifies the number of groups to divide a
              convolution into (set `groups = in_chs` for Depthwise Convolutions). `in_chs`
              and `out_chs` must be divisible by `groups`.
  - `use_bias`: Trainable bias can be disabled entirely by setting this to `false`.
  - `allow_fast_activation`: If `true`, then certain activations can be approximated with
    a faster version. The new activation function will be given by
    `NNlib.fast_act(activation)`

## Inputs

  - `x`: Data satisfying `ndims(x) == N + 2 && size(x, N - 1) == in_chs`, i.e.
         `size(x) = (I_N, ..., I_1, C_in, N)`

## Returns

  - Output of the convolution transpose `y` of size `(O_N, ..., O_1, C_out, N)` where
  - Empty `NamedTuple()`

## Parameters

  - `weight`: Convolution Transpose kernel
  - `bias`: Bias (present if `use_bias=true`)
"""
@concrete struct ConvTranspose{N, use_bias, M} <: AbstractExplicitLayer
    activation
    in_chs::Int
    out_chs::Int
    kernel_size::NTuple{N, Int}
    stride::NTuple{N, Int}
    pad::NTuple{M, Int}
    dilation::NTuple{N, Int}
    groups::Int
    init_weight
    init_bias
end

function ConvTranspose(
        k::NTuple{N, Integer}, ch::Pair{<:Integer, <:Integer}; activation=identity,
        init_weight=glorot_uniform, init_bias=zeros32, stride=1, pad=0, dilation=1,
        use_bias::Bool=true, groups=1, allow_fast_activation::Bool=true) where {N}
    stride = _expand(Val(N), stride)
    dilation = _expand(Val(N), dilation)
    pad = if pad isa SamePad
        _calc_padding(pad, k .- stride .+ 1, dilation, stride)
    else
        _calc_padding(pad, k, dilation, stride)
    end
    activation = allow_fast_activation ? NNlib.fast_act(activation) : activation

    return ConvTranspose{N, use_bias, length(pad)}(
        activation, first(ch), last(ch), k, stride,
        pad, dilation, groups, init_weight, init_bias)
end

function initialparameters(
        rng::AbstractRNG, c::ConvTranspose{N, use_bias}) where {N, use_bias}
    weight = _convfilter(
        rng, c.kernel_size, c.out_chs => c.in_chs; init=c.init_weight, c.groups)
    if use_bias
        return (; weight, bias=c.init_bias(rng, ntuple(_ -> 1, N)..., c.out_chs, 1))
    else
        return (; weight)
    end
end

function parameterlength(c::ConvTranspose{N, use_bias}) where {N, use_bias}
    return prod(c.kernel_size) * c.in_chs * c.out_chs ÷ c.groups +
           (use_bias ? c.out_chs : 0)
end

@inline function (c::ConvTranspose{N, false})(
        x::AbstractArray, ps, st::NamedTuple) where {N}
    y = match_eltype(c, ps, st, x)
    cdims = _conv_transpose_dims(
        y, ps.weight; c.stride, padding=c.pad, c.dilation, c.groups)
    return fast_activation!!(c.activation, _conv_transpose(y, ps.weight, cdims)), st
end

@inline function (c::ConvTranspose{N, true})(x::AbstractArray, ps, st::NamedTuple) where {N}
    cdims = _conv_transpose_dims(
        x, ps.weight; c.stride, padding=c.pad, c.dilation, c.groups)
    return (
        __apply_bias_activation(
            c.activation, _conv_transpose(x, ps.weight, cdims), ps.bias),
        st)
end

function Base.show(io::IO, l::ConvTranspose)
    print(io, "ConvTranspose(", l.kernel_size)
    print(io, ", ", l.in_chs, " => ", l.out_chs)
    _print_convtranspose_opt(io, l)
    return print(io, ")")
end

function _print_convtranspose_opt(io::IO, l::ConvTranspose{N, use_bias}) where {N, use_bias}
    l.activation == identity || print(io, ", ", l.activation)
    all(==(0), l.pad) || print(io, ", pad=", __tuple_string(l.pad))
    all(==(1), l.stride) || print(io, ", stride=", __tuple_string(l.stride))
    all(==(1), l.dilation) || print(io, ", dilation=", __tuple_string(l.dilation))
    (l.groups == 1) || print(io, ", groups=", l.groups)
    (use_bias == false) && print(io, ", use_bias=false")
    return nothing
end
