## Solve the classical GP Regression ##
mutable struct Analytic{T<:Real} <: Inference{T}
    ϵ::T #Convergence criteria
    nIter::Integer #Number of steps performed
    Stochastic::Bool #Use of mini-batches
    nSamples::Int64
    nMinibatch::Int64 #Size of mini-batches
    MBIndices::Vector{Int64} #Indices of the minibatch
    ρ::T #Stochastic Coefficient
    HyperParametersUpdated::Bool #To know if the inverse kernel matrix must updated
    xview::AbstractArray
    yview::AbstractVector
    function Analytic{T}(
        ϵ::T,
        nIter::Integer,
        Stochastic::Bool,
        nSamples::Integer,
        MBIndices::AbstractVector,
        ρ::T,
    ) where {T}
        return new{T}(ϵ, nIter, Stochastic, nSamples, nSamples, MBIndices, ρ, true)
    end
end

"""
    Analytic(;ϵ::T=1e-5)

Analytic inference structure for the classical GP regression

**Keyword arguments**
    - `ϵ::T` : convergence criteria, which can be user defined
"""
function Analytic(; ϵ::T = 1e-5) where {T<:Real}
    Analytic{T}(ϵ, 0, false, 1, collect(1:1), T(1.0))
end


function Base.show(io::IO,inference::Analytic{T}) where T
    print(io,"Analytic Inference")
end


function init_inference(
    inference::Analytic{T},
    nLatent::Integer,
    nFeatures::Integer,
    nSamples::Integer,
    nSamplesUsed::Integer,
) where {T<:Real}
    inference.nSamples = nSamples
    inference.nMinibatch = nSamples
    inference.MBIndices = 1:nSamples
    inference.ρ = one(T)
    return inference
end

function analytic_updates!(model::GP{T}) where {T}
    first(model.f).μ = first(model.f).K \ (model.y - first(model.f).μ₀(model.X))
    if !isnothing(model.likelihood.opt_noise)
        model.likelihood.σ² .= mean(abs2, model.y .- first(model.f).μ)
    end
end

xview(inf::Analytic) = inf.xview
yview(inf::Analytic) = inf.yview

nMinibatch(inf::Analytic) = inf.nMinibatch

getρ(inf::Analytic) = inf.ρ

MBIndices(inf::Analytic) = inf.MBIndices
