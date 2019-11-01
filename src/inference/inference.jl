
include("learning_rate/alrsvi.jl")
include("learning_rate/inversedecay.jl")
include("vi_optimizers.jl")
include("analytic.jl")
include("analyticVI.jl")
include("gibbssampling.jl")
include("numericalVI.jl")

function post_process!(model::AbstractGP{T,<:Likelihood,<:Inference}) where {T}
    nothing
end

Base.length(::Inference) = 1

Base.iterate(l::Inference) = (l,nothing)
Base.iterate(l::Inference, ::Any) = nothing

isstochastic(l::Inference) = l.Stochastic

const GibbsorVI = Union{<:GibbsSampling,<:AnalyticVI}

#Conversion from natural to standard distribution parameters
function global_update!(gp::Abstract_GP) where {T,L}
    gp.Σ .= -0.5*inv(gp.η₂)
    gp.μ .= gp.Σ*gp.η₁
end
