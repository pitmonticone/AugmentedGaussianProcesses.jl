"""
Class for multi-output sparse variational Gaussian Processes

```julia
MOSVGP(X::AbstractArray{T},y::AbstractVector{AbstractArray{T}},kernel::Kernel,
    likelihood::AbstractVector{Likelihoods},inference::InferenceType, nInducingPoints::Int;
    verbose::Int=0,optimiser=ADAM(0.001),atfrequency::Int=1,
    mean::Union{<:Real,AbstractVector{<:Real},PriorMean}=ZeroMean(),
    Zoptimizer=false,
    ArrayType::UnionAll=Vector)
```

Argument list :

**Mandatory arguments**
 - `X` : input features, should be a matrix N×D where N is the number of observation and D the number of dimension
 - `y` : input labels, can be either a vector of labels for multiclass and single output or a matrix for multi-outputs (note that only one likelihood can be applied)
 - `kernel` : covariance function, can be either a single kernel or a collection of kernels for multiclass and multi-outputs models
 - `likelihood` : likelihood of the model, currently implemented : Gaussian, Student-T, Laplace, Bernoulli (with logistic link), Bayesian SVM, Multiclass (softmax or logistic-softmax) see [`Likelihood`](@ref likelihood_user)
 - `inference` : inference for the model, can be analytic, numerical or by sampling, check the model documentation to know what is available for your likelihood see the [`Compatibility table`](@ref compat_table)
 - `nInducingPoints` : number of inducing points
**Optional arguments**
 - `verbose` : How much does the model print (0:nothing, 1:very basic, 2:medium, 3:everything)
- `optimiser` : Optimiser used for the kernel parameters. Should be an Optimiser object from the [Flux.jl](https://github.com/FluxML/Flux.jl) library, see list here [Optimisers](https://fluxml.ai/Flux.jl/stable/training/optimisers/) and on [this list](https://github.com/theogf/AugmentedGaussianProcesses.jl/tree/master/src/inference/optimisers.jl). Default is `ADAM(0.001)`
 - `atfrequency` : Choose how many variational parameters iterations are between hyperparameters optimization
 - `mean` : PriorMean object, check the documentation on it [`MeanPrior`](@ref meanprior)
 - `IndependentPriors` : Flag for setting independent or shared parameters among latent GPs
- `Zoptimiser` : Optimiser used for inducing points locations. Should be an Optimiser object from the [Flux.jl](https://github.com/FluxML/Flux.jl) library, see list here [Optimisers](https://fluxml.ai/Flux.jl/stable/training/optimisers/) and on [this list](https://github.com/theogf/AugmentedGaussianProcesses.jl/tree/master/src/inference/optimisers.jl). Default is `ADAM(0.001)`
 - `ArrayType` : Option for using different type of array for storage (allow for GPU usage)
"""
mutable struct MOSVGP{T<:Real,TLikelihood<:Likelihood{T},TInference<:Inference,N,Q} <: AbstractGP{T,TLikelihood,TInference,N}
    X::Matrix{T} #Feature vectors
    y::Vector #Output (-1,1 for classification, real for regression, matrix for multiclass)
    nSamples::Int64 # Number of data points
    nDim::Int64 # Number of covariates per data point
    nFeatures::Int64 # Number of features of the GP (equal to number of points)
    nLatent::Int64 # Number of latent GPs
    nTask::Int64
    nf_per_task::Vector{Int64}
    f::NTuple{Q,_SVGP}
    likelihood::Vector{TLikelihood}
    inference::TInference
    A::Array{T,3}
    A_opt
    verbose::Int64
    atfrequency::Int64
    Trained::Bool
end



function MOSVGP(
            X::AbstractArray{T},y::AbstractVector{<:AbstractVector},kernel::Kernel,
            likelihood::TLikelihood,inference::TInference,nLatent::Int,nInducingPoints::Int;
            verbose::Int=0,optimiser=ADAM(0.01),atfrequency::Int=1,
            mean::Union{<:Real,AbstractVector{<:Real},PriorMean}=ZeroMean(), variance::Real = 1.0,Aoptimiser=ADAM(0.01),
            Zoptimizer=false,
            ArrayType::UnionAll=Vector) where {T<:Real,TLikelihood<:Likelihood,TInference<:Inference}

            @assert length(y) > 0 "y should not be an empty vector"
            nTask = length(y)
            likelihoods = [deepcopy(likelihood) for _ in 1:nTask]
            nf_per_task = zeros(Int64,nTask)
            corrected_y = Vector(undef,nTask)
            for i in 1:nTask
                X,corrected_y[i],nf_per_task[i],likelihoods[i] = check_data!(X,y[i],likelihoods[i])
            end

            @assert inference isa AnalyticVI "The inference object should be of type `AnalyticVI`"
            @assert implemented(likelihood, inference) "The $likelihood is not compatible or implemented with the $inference"

            nSamples = size(X,1); nDim = size(X,2);
            if isa(optimiser,Bool)
                optimiser = optimiser ? ADAM(0.01) : nothing
            end
            if isa(AOptimiser,Bool)
                Aoptimiser = Aoptimiser ? ADAM(0.01) : nothing
            end
            @assert nInducingPoints > 0 "The number of inducing points is incorrect (negative or bigger than number of samples)"
            if nInducingPoints > nSamples
                @warn "Number of inducing points bigger than the number of points : reducing it to the number of samples: $(nSamples)"
                nInducingPoints = nSamples
            end
            if nInducingPoints == nSamples
                Z = X
            else
                Z = KMeansInducingPoints(X,nInducingPoints,nMarkov=10)
            end
            if isa(Zoptimizer,Bool)
                Zoptimizer = Zoptimizer ? Adam(α=0.01) : nothing
            end
            Z = InducingPoints(Z,Zoptimizer)

            nFeatures = nInducingPoints

            if typeof(mean) <: Real
                mean = ConstantMean(mean)
            elseif typeof(mean) <: AbstractVector{<:Real}
                mean = EmpiricalMean(mean)
            end

            nMinibatch = nSamples
            if inference.Stochastic
                @assert inference.nMinibatch > 0 && inference.nMinibatch < nSamples "The size of mini-batch $(inference.nMinibatch) is incorrect (negative or bigger than number of samples), please set nMinibatch correctly in the inference object"
                nMinibatch = inference.nMinibatch
            end

            latent_f = ntuple( _ -> _SVGP{T}(nFeatures,nMinibatch,Z,kernel,mean,variance,optimiser),nLatent)

            dpos = Normal(0.5,0.5)
            dneg = Normal(-0.5,0.5)
            A = zeros(T,nTask,nf_per_task[1],nLatent)
            for i in eachindex(A)
                p = rand(0:1)
                A[i] =  rand(Normal(0.0,1.0))#p*rand(dpos) + (1-p)*rand(dneg)
            end

            likelihoods .= init_likelihood.(likelihoods,inference,nf_per_task,nMinibatch,nFeatures)
            inference = tuple_inference(inference,nLatent,nFeatures,nSamples,nMinibatch)
            inference.xview = view(X,1:nMinibatch,:)
            inference.yview = view(y,:)

            model = MOSVGP{T,TLikelihood,typeof(inference),nTask,nLatent}(X,corrected_y,
                    nSamples, nDim, nFeatures, nLatent,
                    nTask, nf_per_task,
                    latent_f,likelihoods,inference,A,Aoptimizer,
                    verbose,atfrequency,false)
            # if isa(inference.optimizer,ALRSVI)
                # init!(model.inference,model)
            # end
            # return model
end

function Base.show(io::IO,model::MOSVGP{T,<:Likelihood,<:Inference}) where {T}
    print(io,"Multioutput Sparse Variational Gaussian Process with the likelihoods $(model.likelihood) infered by $(model.inference) ")
end

@traitimpl IsMultiOutput{MOSVGP}

@traitfn function mean_f(model::TGP) where {T,TGP<:AbstractGP{T};IsMultiOutput{TGP}}
    μ_q = mean_f.(model.f)
    μ_f = []
    for i in 1:model.nTask
        x = ntuple(_->zeros(T,model.inference.nMinibatch),model.nf_per_task[i])
        for j in 1:model.nf_per_task[i]
            x[j] .= sum(vec(model.A[i,j,:]) .* μ_q)
        end
        push!(μ_f,x)
    end
    return μ_f
end

@traitfn function diag_cov_f(model::TGP) where {T,TGP<:AbstractGP{T};IsMultiOutput{TGP}}
    Σ_q = diag_cov_f.(model.f)
    Σ_f = []
    for i in 1:model.nTask
        x = ntuple(_->zeros(T,model.inference.nMinibatch),model.nf_per_task[i])
        for j in 1:model.nf_per_task[i]
            x[j] .= sum(vec(model.A[i,j,:]).^2 .* Σ_q)
        end
        push!(Σ_f,x)
    end
    return Σ_f
end

@traitfn get_y(model::TGP) where {T,TGP<:AbstractGP{T};IsMultiOutput{TGP}} = view_y.(model.likelihood,model.y,[model.inference.MBIndices])

## return the linear sum of the expectation gradient given μ ##
@traitfn function ∇E_μ(model::TGP) where {T,TGP<:AbstractGP{T};IsMultiOutput{TGP}}
    ∇ = [zeros(T,model.inference.nMinibatch) for _ in 1:model.nLatent]
    ∇Eμs = ∇E_μ.(model.likelihood,model.inference.vi_opt[1:1],get_y(model))
    ∇EΣs = ∇E_Σ.(model.likelihood,model.inference.vi_opt[1:1],get_y(model))
    μ_f = mean_f.(model.f)
    for t in 1:model.nTask
        for j in 1:model.nf_per_task[t]
            for q in 1:model.nLatent
                ∇[q] .+= model.A[t,j,q] * (∇Eμs[t][j]  - 2*∇EΣs[t][j].*sum(model.A[t,j,qq]*μ_f[qq] for qq in 1:model.nLatent if qq!=q))
            end
        end
    end
    return ∇
end

## return the linear sum of the expectation gradient given diag(Σ) ##
@traitfn function ∇E_Σ(model::TGP) where {T,TGP<:AbstractGP{T};IsMultiOutput{TGP}}
    ∇ = [zeros(T,model.inference.nMinibatch) for _ in 1:model.nLatent]
    ∇Es = ∇E_Σ.(model.likelihood,model.inference.vi_opt[1:1],get_y(model))
    for t in 1:model.nTask
        for j in 1:model.nf_per_task[t]
            for q in 1:model.nLatent
                ∇[q] .+= model.A[t,j,q]^2 * ∇Es[t][j]
            end
        end
    end
    return ∇
end

@traitfn get_Z(model::TGP) where {T,TGP<:AbstractGP{T};IsMultiOutput{TGP}} = getproperty.(getproperty.(model.f,:Z),:Z)


@traitfn function update_A!(model::TGP) where {T,TGP<:AbstractGP{T};IsMultiOutput{TGP}}
    if !isnothing(model.A_opt)
        μ_f = mean_f.(model.f) # κμ
        Σ_f = diag_cov_f.(model.f) #Diag(K̃ + κΣκ)
        ∇Eμ = ∇E_μ.(model.likelihood,model.inference.vi_opt[1:1],get_y(model))
        ∇EΣ = ∇E_Σ.(model.likelihood,model.inference.vi_opt[1:1],get_y(model))
        new_A = zero(model.A)
        ∇A = zero(model.A)
        for t in 1:model.nTask
            for j in 1:model.nf_per_task[t]
                for q in 1:model.nLatent
                    x1 = dot(∇Eμ[t][j],μ_f[q])-2*dot(∇EΣ[t][j],μ_f[q].*sum(model.A[t,j,qq]*μ_f[qq] for qq in 1:model.nLatent if qq!=q))
                    x2 = dot(∇EΣ[t][j],abs2.(μ_f[q])+Σ_f[q])
                    new_A[t,j,q] = x1/(2*x2)
                    ∇A[t,j,q] = x1 - 2*model.A[t,j,q]*x2
                end
                # model.A[t,j,:]./=sum(model.A[t,j,:])
            end
        end
        model.A .+= Flux.Optimise.apply!(model.A_opt,model.A,∇A)
        # model.A .= model.A./vec(sum(model.A,dims=3))
        # model.A .= new_A
    end
end
