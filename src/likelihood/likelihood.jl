include("regression.jl")
include("classification.jl")
include("multiclass.jl")
include("event.jl")
include("generic_likelihood.jl")
include("customlikelihood.jl")
function pdf(l::Likelihood{T},y::Real,f::Real) where T
    @error "pdf not implemented"
end

@inline logpdf(l::Likelihood{T},y::Real,f::Real) where T = log(pdf(l,y,f))

isaugmented(::Likelihood) = false

Base.length(::Likelihood) = 1

Base.iterate(l::Likelihood) = (l,nothing)
Base.iterate(l::Likelihood, ::Any) = nothing

Base.setindex!(veclike::NTuple{N,L},l::Likelihood,i::Int) where {N,L<:Likelihood} = veclike[i] = l

@inline grad_log_pdf(l::Likelihood{T},y::Real,f::AbstractVector) where {T<:Real} = ForwardDiff.gradient(x->logpdf(l,y,x),f)
@inline hessian_log_pdf(l::Likelihood{T},y::Real,f::AbstractVector) where {T<:Real} = diag(ForwardDiff.hessian(x->logpdf(l,y,x),f))
