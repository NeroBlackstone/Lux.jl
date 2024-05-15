"""
    StatefulLuxLayer(model, ps, st; st_fixed_type = Val(true))  # deprecated
    StatefulLuxLayer{ST}(model, ps, st)

!!! warning

    This is not a Lux.AbstractExplicitLayer

A convenience wrapper over Lux layers which stores the parameters and states internally.
This is meant to be used in internal implementation of layers.

## Usecases

  - Internal implementation of [`@compact`](@ref) heavily uses this layer.
  - In SciML codebases where propagating state might involving
    [`Box`ing](https://github.com/JuliaLang/julia/issues/15276). For a motivating example,
    see the Neural ODE tutorial.
  - Facilitates Nested AD support in Lux. For more details on this feature, see the
    [Nested AD Manual Page](@ref nested_autodiff).

## Arguments

  - `model`: A Lux layer
  - `ps`: The parameters of the layer. This can be set to `nothing`, if the user provides
    the parameters on function call
  - `st`: The state of the layer

## Keyword Arguments

  - `st_fixed_type`: If `Val(true)`, then the type of the `state` is fixed, i.e.,
    `typeof(last(model(x, ps, st))) == st`. If this is not the case, then `st_fixed_type`
    must be set to `Val(false)`. If `st_fixed_type` is set to `Val(false)`, then type
    stability is not guaranteed.

## Inputs

  - `x`: The input to the layer
  - `ps`: The parameters of the layer. Optional, defaults to `s.ps`

## Outputs

  - `y`: The output of the layer
"""
mutable struct StatefulLuxLayer{ST, M <: AbstractExplicitLayer, psType, stType}
    const model::M
    ps::psType
    st::stType
    st_any::Any

    function StatefulLuxLayer{ST}(model, ps, st, st_any) where {ST}
        return new{ST, typeof(model), typeof(ps), typeof(st)}(model, ps, st, st_any)
    end
end

@inline LuxCore.parameterlength(m::StatefulLuxLayer) = LuxCore.parameterlength(m.model)
@inline LuxCore.statelength(m::StatefulLuxLayer) = LuxCore.statelength(m.model)
@inline LuxCore.apply(m::StatefulLuxLayer, x, p) = m(x, p)

function ConstructionBase.constructorof(::Type{<:StatefulLuxLayer{FT}}) where {FT}
    return StatefulLuxLayer{FT}
end

# TODO: In v0.6 we should deprecate the kwarg and directly using `StatefulLuxLayer{true}`
function StatefulLuxLayer(model::AbstractExplicitLayer, st::NamedTuple; kwargs...)
    return StatefulLuxLayer(model, nothing, st; kwargs...)
end
function StatefulLuxLayer(model::AbstractExplicitLayer, ps, st::NamedTuple;
        st_fixed_type::Val{ST}=Val(true)) where {ST}
    Base.depwarn("`st_fixed_type` is deprecated. Use `StatefulLuxLayer{ST}` instead.",
        :StatefulLuxLayer)
    return StatefulLuxLayer{ST}(model, ps, st)
end
function StatefulLuxLayer{true}(model::AbstractExplicitLayer, ps, st::NamedTuple)
    return StatefulLuxLayer{true}(model, ps, st, nothing)
end
function StatefulLuxLayer{false}(model::AbstractExplicitLayer, ps, st::NamedTuple)
    return StatefulLuxLayer{false}(model, ps, nothing, st)
end

function (s::StatefulLuxLayer{true})(x, p=s.ps)
    y, st = apply(s.model, x, p, s.st)
    CRC.@ignore_derivatives begin
        s.st = st
    end
    return y
end

function (s::StatefulLuxLayer{false})(x, p=s.ps)
    y, st = apply(s.model, x, p, s.st_any)
    CRC.@ignore_derivatives begin
        s.st_any = st
    end
    return y
end

function CRC.rrule(::Type{<:StatefulLuxLayer{true}}, model::AbstractExplicitLayer, ps, st)
    slayer = StatefulLuxLayer{true}(model, ps, st, nothing)
    ∇StatefulLuxLayer(Δ) = NoTangent(), NoTangent(), Δ.ps, NoTangent(), NoTangent()
    return slayer, ∇StatefulLuxLayer
end

function CRC.rrule(::Type{<:StatefulLuxLayer{false}}, model::AbstractExplicitLayer, ps, st)
    slayer = StatefulLuxLayer{false}(model, ps, nothing, st)
    ∇StatefulLuxLayer(Δ) = NoTangent(), NoTangent(), Δ.ps, NoTangent(), NoTangent()
    return slayer, ∇StatefulLuxLayer
end

for FT in (true, false)
    @eval function CRC.rrule(
            ::Type{<:StatefulLuxLayer{$(FT)}}, model::AbstractExplicitLayer, ps, st, st_any)
        slayer = StatefulLuxLayer{$(FT)}(model, ps, st, st_any)
        ∇StatefulLuxLayer(Δ) = NoTangent(), NoTangent(), Δ.ps, NoTangent(), NoTangent()
        return slayer, ∇StatefulLuxLayer
    end
end

function CRC.rrule(::typeof(getproperty), s::StatefulLuxLayer, name::Symbol)
    y = getproperty(s, name)
    ∇getproperty = @closure Δ -> begin
        name === :ps && return NoTangent(), (; ps=Δ), NoTangent()
        return NoTangent(), NoTangent(), NoTangent()
    end
    return y, ∇getproperty
end
