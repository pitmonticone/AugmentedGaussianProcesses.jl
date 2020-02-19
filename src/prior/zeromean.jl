struct ZeroMean{T<:Real} <: PriorMean{T} end

"""
ZeroMean
```julia
ZeroMean()
```
Construct a mean prior set to 0 and cannot be changed.
"""
function ZeroMean()
    ZeroMean{Float64}()
end

update!(opt,μ::ZeroMean{T},grad::AbstractVector{T},x) where {T<:Real} = nothing

array(μ::ZeroMean{T},length::Int) where {T<:Real} = zeros(T,length)

(μ::ZeroMean{T})(x::Real) where {T<:Real} = zero(T)
(μ::ZeroMean{T})(x::AbstractMatrix) where {T<:Real} = zeros(T,size(x,1))
