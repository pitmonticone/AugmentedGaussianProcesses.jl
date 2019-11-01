"""
```julia
    LogisticSoftMaxLikelihood()
```

The multiclass likelihood with a logistic-softmax mapping: :
```math
p(y=i|{fₖ}₁ᴷ) = σ(fᵢ)/∑ₖ σ(fₖ)
```
where `σ` is the logistic function.
This likelihood has the same properties as [softmax](https://en.wikipedia.org/wiki/Softmax_function).
---

For the analytical version, the likelihood is augmented multiple times. More details can be found in the paper [Multi-Class Gaussian Process Classification Made Conjugate: Efficient Inference via Data Augmentation](https://arxiv.org/abs/1905.09670)
"""
struct LogisticSoftMaxLikelihood{T<:Real} <: MultiClassLikelihood{T}
    Y::AbstractVector{BitVector} #Mapping from instances to classes
    class_mapping::AbstractVector{Any} # Classes labels mapping
    ind_mapping::Dict{Any,Int} # Mapping from label to index
    y_class::AbstractVector{Int64} # GP Index for each sample
    c::AbstractVector{AbstractVector{T}} # Second moment of fₖ
    α::AbstractVector{T} # Variational parameter of Gamma distribution
    β::AbstractVector{T} # Variational parameter of Gamma distribution
    θ::AbstractVector{AbstractVector{T}} # Variational parameter of Polya-Gamma distribution
    γ::AbstractVector{AbstractVector{T}} # Variational parameter of Poisson distribution
    function LogisticSoftMaxLikelihood{T}() where {T<:Real}
        new{T}()
    end
    function LogisticSoftMaxLikelihood{T}(Y::AbstractVector{<:BitVector},
    class_mapping::AbstractVector, ind_mapping::Dict{<:Any,<:Int},y_class::AbstractVector{<:Int}) where {T<:Real}
        new{T}(Y,class_mapping,ind_mapping,y_class)
    end
    function LogisticSoftMaxLikelihood{T}(Y::AbstractVector{<:BitVector},
    class_mapping::AbstractVector, ind_mapping::Dict{<:Any,<:Int},y_class::AbstractVector{<:Int},
    c::AbstractVector{<:AbstractVector{<:Real}}, α::AbstractVector{<:Real},
    β::AbstractVector, θ::AbstractVector{<:AbstractVector},γ::AbstractVector{<:AbstractVector{<:Real}}) where {T<:Real}
        new{T}(Y,class_mapping,ind_mapping,y_class,c,α,β,θ,γ)
    end
end

function LogisticSoftMaxLikelihood()
    LogisticSoftMaxLikelihood{Float64}()
end

function pdf(l::LogisticSoftMaxLikelihood,f::AbstractVector)
    logisticsoftmax(f)
end


function pdf(l::LogisticSoftMaxLikelihood,y::Integer,f::AbstractVector)
    logisticsoftmax(f)[y]
end

function Base.show(io::IO,model::LogisticSoftMaxLikelihood{T}) where T
    print(io,"Logistic-Softmax Likelihood")
end


function init_likelihood(likelihood::LogisticSoftMaxLikelihood{T},inference::Inference{T},nLatent::Integer,nSamplesUsed::Integer,nFeatures::Integer) where T
    if inference isa AnalyticVI || inference isa GibbsSampling
        c = [ones(T,nSamplesUsed) for i in 1:nLatent]
        α = nLatent*ones(T,nSamplesUsed)
        β = nLatent*ones(T,nSamplesUsed)
        θ = [abs.(rand(T,nSamplesUsed))*2 for i in 1:nLatent]
        γ = [abs.(rand(T,nSamplesUsed)) for i in 1:nLatent]
        LogisticSoftMaxLikelihood{T}(likelihood.Y,likelihood.class_mapping,likelihood.ind_mapping,likelihood.y_class,c,α,β,θ,γ)
    else
        return likelihood
    end
end

get_y(model::AbstractGP{T,L}) = view.(model.likelihood.Y,[model.inferences.MBIndices])

## Local Updates##
function local_updates!(l::LogisticSoftMaxLikelihood,y,μ::NTuple{N,<:AbstractVector},Σ::NTuple{N,<:AbstractVector}) where {T,N}
    l.c .= broadcast((Σ,μ)->sqrt.(Σ+abs2.(μ)),Σ,μ)
    for _ in 1:2
        l.γ .= broadcast(
            (β,c,μ,ψα)->0.5 / β * exp.(ψα) .* safe_expcosh.(-0.5*μ, 0.5*c),                                    l.β,l.c,μ,[digamma.(l.α)])
        l.α .= 1.0.+(l.γ...)
    end
    l.θ .= broadcast((y,γ,c)->0.5*(y+γ)./c.*tanh.(0.5.*c),
                                    y,l.γ,l.c)
    return nothing
end

function sample_local!(model::VGP{T,<:LogisticSoftMaxLikelihood,<:GibbsSampling}) where {T}
    model.likelihood.γ .= broadcast(μ::AbstractVector{<:Real}->rand.(Poisson.(0.5*model.likelihood.α.*safe_expcosh.(-0.5*μ,0.5*μ))), model.μ)
    model.likelihood.α .= rand.(Gamma.(1.0.+(model.likelihood.γ...),1.0./model.likelihood.β))
    pg = PolyaGammaDist()
    model.likelihood.θ .= broadcast((y::BitVector,γ::AbstractVector{<:Real},μ::AbstractVector{<:Real})->draw.([pg],y.+γ,μ),model.likelihood.Y,model.likelihood.γ,model.μ)
    return nothing
end

## Global Gradient Section ##

@inline ∇E_μ(l::LogisticSoftMaxLikelihood,::AVIOptimizer,y) where {T} = 0.5.*(y.-l.γ)
@inline ∇E_Σ(l::LogisticSoftMaxLikelihood,::AVIOptimizer,y) where {T} = 0.5.*l.θ

## ELBO Section ##

function ELBO(model::AbstractGP{T,<:LogisticSoftMaxLikelihood,<:AnalyticVI}) where {T}
    return expec_logpdf(model) - GaussianKL(model) - GammaEntropy(model) - PoissonKL(model) - PolyaGammaKL(model)
end

function expec_logpdf(model::VGP{T,<:LogisticSoftMaxLikelihood,<:AnalyticVI}) where {T}
    tot = -length(y)*logtwo
    tot += -sum(sum(l.γ.+l.Y))*logtwo
    tot +=  0.5*sum(broadcast((y,μ,γ,θ,c)->sum(μ.*(y-γ)-θ.*abs2.(c)),
                    model.likelihood.Y,model.μ,model.likelihood.γ,model.likelihood.θ,model.likelihood.c))
    return tot
end

function expecLogLikelihood(model::SVGP{T,<:LogisticSoftMaxLikelihood,<:AnalyticVI}) where {T}
    model.likelihood.c .= broadcast((μ::AbstractVector,Σ::AbstractMatrix,κ::AbstractMatrix,K̃::AbstractVector)->sqrt.(K̃+opt_diag(κ*Σ,κ)+abs2.(κ*μ)),
                                    model.μ,model.Σ,model.κ,model.K̃)
    tot = -model.inference.nSamplesUsed*logtwo
    tot += -sum(sum.(model.likelihood.γ.+getindex.(model.likelihood.Y,[model.inference.MBIndices])))*logtwo
    tot += 0.5*sum(broadcast((y,κμ,γ,θ,c)->sum((κμ).*(y[model.inference.MBIndices]-γ)-θ.*abs2.(c)),
                    model.likelihood.Y,model.κ.*model.μ,model.likelihood.γ,model.likelihood.θ,model.likelihood.c))
    return model.inference.ρ*tot
end

function PolyaGammaKL(model::VGP{T,<:LogisticSoftMaxLikelihood}) where {T}
    sum(broadcast(PolyaGammaKL,model.likelihood.Y.+model.likelihood.γ,model.likelihood.c,model.likelihood.θ))
end

function PolyaGammaKL(model::SVGP{T,<:LogisticSoftMaxLikelihood}) where {T}
    model.inference.ρ*sum(broadcast(PolyaGammaKL,getindex.(model.likelihood.Y,[model.inference.MBIndices]).+model.likelihood.γ,model.likelihood.c,model.likelihood.θ))
end

function PoissonKL(model::AbstractGP{T,<:LogisticSoftMaxLikelihood}) where {T}
    return model.inference.ρ*sum(broadcast(PoissonKL,model.likelihood.γ,[model.likelihood.α./model.likelihood.β],[digamma.(model.likelihood.α).-log.(model.likelihood.β)]))
end

## Numerical Gradient Section ##

function grad_samples(model::AbstractGP{T,<:LogisticSoftMaxLikelihood,<:NumericalVI},samples::AbstractMatrix{T},index::Integer) where {T}
    class = model.likelihood.y_class[index]::Int64
    grad_μ = zeros(T,model.nLatent)
    grad_Σ = zeros(T,model.nLatent)
    g_μ = similar(grad_μ)
    nSamples = size(samples,1)
    @views @inbounds for i in 1:nSamples
        σ = logistic.(samples[i,:])
        samples[i,:]  .= logisticsoftmax(samples[i,:])
        s = samples[i,class]
        g_μ .= grad_logisticsoftmax(samples[i,:],σ,class)/s
        grad_μ += g_μ
        grad_Σ += diaghessian_logisticsoftmax(samples[i,:],σ,class)/s - abs2.(g_μ)
    end
    for k in 1:model.nLatent
        model.inference.ν[k][index] = -grad_μ[k]/nSamples
        model.inference.λ[k][index] = grad_Σ[k]/nSamples
    end
end

function log_like_samples(model::AbstractGP{T,<:LogisticSoftMaxLikelihood},samples::AbstractMatrix,index::Integer) where {T}
    class = model.likelihood.y_class[index]
    nSamples = size(samples,1)
    loglike = zero(T)
    for i in 1:nSamples
        σ = logistic.(samples[i,:])
        loglike += log(σ[class])-log(sum(σ))
    end
    return loglike/nSamples
end

function grad_logisticsoftmax(s::AbstractVector{<:Real},σ::AbstractVector{<:Real},i::Integer)
    s[i]*(δ.(i,eachindex(σ)).-s).*(1.0.-σ)
end

function diaghessian_logisticsoftmax(s::AbstractVector{<:Real},σ::AbstractVector{<:Real},i::Integer)
    s[i]*(1.0.-σ).*(
    abs2.(δ.(i,eachindex(σ))-s).*(1.0.-σ)
    -s.*(1.0.-s).*(1.0.-σ)
    -σ.*(δ.(i,eachindex(σ))-s))
end

function hessian_logisticsoftmax(s::AbstractVector{T},σ::AbstractVector{T},i::Integer) where {T<:Real}
    m = length(s)
    hessian = zeros(T,m,m)
    @inbounds for j in 1:m
        for k in 1:m
            hessian[j,k] = (1-σ[j])*s[i]*(
            (δ(i,k)-s[k])*(1.0-σ[k])*(δ(i,j)-s[j])
            -s[j]*(δ(j,k)-s[k])*(1.0-σ[k])
            -δ(k,j)*σ[j]*(δ(i,j)-s[j]))
        end
    end
    return hessian
end
