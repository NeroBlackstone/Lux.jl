# Low-Level functions
@inline function Lux.__partials(::Type{Tag}, x, i) where {Tag}
    x isa ForwardDiff.Dual && return ForwardDiff.partials(Tag, x, i)
    x isa AbstractArray && return ForwardDiff.partials.(Tag, x, i)
    map_fn = @closure(xᵢ->Lux.__partials(Tag, xᵢ, i))
    x isa Tuple && return map(map_fn, x)
    x isa NamedTuple && return NamedTuple{keys(x)}(map(map_fn, values(x)))
    x isa CRC.AbstractTangent && return Lux.__partials(Tag, CRC.backing(x), i)
    x === nothing && return nothing
    return fmap(map_fn, x)
end

@inline function Lux.__dualify(::Type{Tag}, ::Type{T}, x, u) where {Tag, T}
    if x isa AbstractArray
        return ForwardDiff.Dual{
            Tag, T, 1}.(x, ForwardDiff.Partials{1, T}.(tuple.(reshape(u, size(x)))))
    end
    x isa Tuple && return map((xᵢ, uᵢ) -> Lux.__dualify(Tag, T, xᵢ, uᵢ), x, u)
    x isa NamedTuple &&
        return NamedTuple{keys(x)}(map((xᵢ, uᵢ) -> Lux.__dualify(Tag, T, xᵢ, uᵢ), x, u))
    return fmap((xᵢ, uᵢ) -> Lux.__dualify(Tag, T, xᵢ, uᵢ), x, u)
end
