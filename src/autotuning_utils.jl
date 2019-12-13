### Compute the gradients using a gradient function and matrices Js ###
for k in (:SqExponentialKernel,:Matern32Kernel,:LinearKernel)
    @eval Flux.@functor($k)
end

for t in (:ARDTransform,:ScaleTransform)
    @eval Flux.@functor($t)
end


function compute_hyperparameter_gradient(k::Kernel,gradient_function::Function,J::IdDict)
    ps = Flux.params(k)
    Δ = IdDict()
    for p in ps
        Δ[p] = vec(mapslices(gradient_function,J[p],dims=[1,2]))
    end
    return Δ
end

## VGP Case
function compute_hyperparameter_gradient(k::KernelWrapper,gradient_function::Function,J::Vector)
    return compute_hyperparameter_gradient.([k],[gradient_function],J)
end

function compute_hyperparameter_gradient(k::KernelWrapper,gradient_function::Function,J::AbstractMatrix)
    return gradient_function(J)
end

function compute_hyperparameter_gradient(k::KernelWrapper,gradient_function::Function,J::Nothing)
    return nothing
end

function compute_hyperparameter_gradient(k::KernelSumWrapper,gradient_function::Function,J::Vector)
    return [map(gradient_function,first(J)),compute_hyperparameter_gradient.(k,[gradient_function],J[end])]
end

function compute_hyperparameter_gradient(k::KernelProductWrapper,gradient_function::Function,J::Vector)
    return compute_hyperparameter_gradient.(k,J)
end

## SVGP Case
function compute_hyperparameter_gradient(k::KernelWrapper,gradient_function::Function,Jmm::Vector,Jnm::Vector,Jnn::Vector,∇E_μ::AbstractVector,∇E_Σ::AbstractVector,i::Inference,viopt::AbstractOptimizer)
    return compute_hyperparameter_gradient.([k],[gradient_function],Jmm,Jnm,Jnn,[∇E_μ],[∇E_Σ],i,[viopt])
end

function compute_hyperparameter_gradient(k::KernelWrapper,gradient_function::Function,Jmm::AbstractMatrix,Jnm::AbstractMatrix,Jnn::AbstractVector,∇E_μ::AbstractVector,∇E_Σ::AbstractVector,i::Inference,viopt::AbstractOptimizer)
    return gradient_function(Jmm,Jnm,Jnn,∇E_μ,∇E_Σ,i,viopt)
end

function compute_hyperparameter_gradient(k::KernelWrapper,gradient_function::Function,Jmm::Nothing,Jnm::Nothing,Jnn::Nothing,∇E_μ::AbstractVector,∇E_Σ::AbstractVector,i::Inference,viopt::AbstractOptimizer)
    return nothing
end

function compute_hyperparameter_gradient(k::KernelSumWrapper,gradient_function::Function,Jmm::Vector,Jnm::Vector,Jnn::Vector,∇E_μ::AbstractVector,∇E_Σ::AbstractVector,i::Inference,viopt::AbstractOptimizer)
    return [map(gradient_function,first(Jmm),first(Jnm),first(Jnn),[∇E_μ],[∇E_Σ],i,[viopt]),compute_hyperparameter_gradient.(k,[gradient_function],Jmm[end],Jnm[end],Jnn[end],[∇E_μ],[∇E_Σ],i,[viopt])]
end

function compute_hyperparameter_gradient(k::KernelProductWrapper,gradient_function::Function,Jmm::Vector,Jnm::Vector,Jnn::Vector,∇E_μ::AbstractVector,∇E_Σ::AbstractVector,i::Inference,viopt::AbstractOptimizer)
    return compute_hyperparameter_gradient.(k,Jmm,Jnm,Jnn,[∇E_μ],[∇E_Σ],i,[viopt])
end

##
function apply_grads_kernel_params!(opt,k::Kernel,Δ::IdDict)
    ps = Flux.params(k)
    for p in ps
      Δ[p] == nothing && continue
      p .+= Flux.Optimise.apply!(opt, p, Δ[p])
      #logσ .+= Flux.Optimise.apply!(opt,gp.σ_k,gp.σ_k.*[grad])
    end
end

function apply_gradients_lengthscale!(k::KernelWrapper,g::AbstractVector) where {T}
    ρ = params(k)
    newρ = []
    for i in 1:length(ρ)
        logρ = log.(ρ[i]) .+ update(k.opts[i],g[i].*ρ[i])
        push!(newρ,exp.(logρ))
    end
    set_params!(k,newρ)
end

function apply_gradients_lengthscale!(k::KernelWrapper{<:Kernel{T,<:ChainTransform}},g::AbstractVector) where {T}
    ρ = params(k)
    newρ = []
    ρt = first(ρ)
    gt = first(g)
    newρt = []
    for i in 1:length(ρt)
        if !isnothing(gt[i])
            if ρt[i] isa Real
                logρ = log(ρt[i]) + update(first(k.opts)[i],first(gt[i])*ρt[i])
                push!(newρt,exp(logρ))
            else
                logρ = log.(ρt[i]) .+ update(first(k.opts)[i],gt[i].*ρt[i])
                push!(newρt,exp.(logρ))
            end
        else
            push!(newρt,ρt[i])
        end
    end
    push!(newρ,newρt)
    if length(g) > 1
        for i in 2:length(ρ)
            logρ = log.(ρ[i]) .+ update(k.opts[i],g[i].*ρ[i])
            push!(newρ,exp.(logρ))
        end
    end
    KernelFunctions.set_params!(k,Tuple(newρ))
end

function apply_gradients_lengthscale!(k::KernelSumWrapper,g::AbstractVector)
    wgrads = first(g)
    w = k.weights
    logw = log.(w) + update(k.opt,w.*wgrads)
    k.weights .= exp.(w)
    apply_gradients_lengthscale!.(k,g[end])
end

function apply_gradients_lengthscale!(k::KernelProductWrapper,g::AbstractVector)
    apply_gradients_lengthscale!.(k,g)
end

function apply_grads_kernel_variance!(opt,gp::Abstract_GP,grad::Real)
    logσ = log.(gp.σ_k)
    logσ .+= Flux.Optimise.apply!(opt,gp.σ_k,gp.σ_k.*[grad])
    gp.σ_k .= exp.(logσ)
end

function apply_gradients_mean_prior!(opt,μ::PriorMean,g::AbstractVector,X::AbstractMatrix)
    update!(opt,μ,g,X)
end

function jacobian(f, ps::Params) # Union{Tracker.Params, Zygote.Params}
    res, back = pullback(f, ps)
    out = IdDict()
    for p in ps
        T = Base.promote_type(eltype(p), eltype(res))
        J = similar(res, T, size(res)..., size(p)...)
        out[p] = J
    end
    delta = fill!(similar(res), 0)
    for k in CartesianIndices(res)
        delta[k] = 1
        grads = back(delta)
        for p in ps
            g = grads[p]
            c = map(_->(:), size(g))
            o = out[p]
            o[k,c...] .= g
        end
        delta[k] = 0
    end
    out
end

function jacobian!(f_back, jacobians, grad_output::AbstractArray)
    for (k, idx) in enumerate(eachindex(grad_output))
        grad_output = fill!(grad_output, 0)
        grad_output[idx] = 1
        grads_input = f_back(grad_output)
        for (jacobian_x, d_x) in zip(jacobians, grads_input)
            jacobian_x[k, :] .= _vec(d_x)
        end
    end
    return jacobians
end

function kernelderivative(k::Kernel,X::AbstractMatrix)
    ps = Flux.params(k)
    jacobian(()->kernelmatrix(k,X,obsdim=1),ps)
end

## Wrapper for iterating over parameters for getting matrices

# Kernel Sum
function kernelderivative(kwrapper::KernelSumWrapper,X::AbstractMatrix)
    return [kernelmatrix.(kwrapper,[X]),kernelderivative.(kwrapper,[X])]
end

function kernelderivative(kwrapper::KernelSumWrapper,X::AbstractMatrix,Y::AbstractMatrix)
    return [kernelmatrix.(kwrapper,[X],[Y]),kernelderivative.(kwrapper,[X],[Y])]
end

function kerneldiagderivative(kwrapper::KernelSumWrapper,X::AbstractMatrix)
    return [kerneldiagmatrix.(kwrapper,[X]),kerneldiagderivative.(kwrapper,[X])]
end

# Kernel Product
recursive_hadamard(A::AbstractMatrix,V::AbstractVector) = recursive_hadamard.([A],V)
recursive_hadamard(A::AbstractMatrix,V::AbstractMatrix) = hadamard(A,V)
recursive_hadamard(A::AbstractVector,V::AbstractVector) = recursive_hadamard.([A],V)
recursive_hadamard(A::AbstractVector,V::AbstractVector{<:Real}) = hadamard(A,V)

function kernelderivative(kwrapper::KernelProductWrapper,X::AbstractMatrix)
    Kproduct = kernelmatrix(kwrapper,X)
    [recursive_hadamard([Kproduct./kernelmatrix(k,X)],kernelderivative(k,X)) for k in k.wrapper]
end

function kernelderivative(kwrapper::KernelProductWrapper,X::AbstractMatrix,Y::AbstractMatrix)
    Kproduct = kernelmatrix(kwrapper,X,Y)
    [recursive_hadamard([Kproduct./kernelmatrix(k,X,Y)],kernelderivative(k,X,Y)) for k in k.wrapper]
end

function kerneldiagderivative(kwrapper::KernelProductWrapper,X::AbstractMatrix)
    Kproduct = kerneldiagmatrix(kwrapper,X)
    [recursive_hadamard([Kproduct./kerneldiagmatrix(k,X)],kerneldiagderivative(k,X)) for k in k.wrapper]
end

# Kernel
function kernelderivative(kernel::KernelWrapper,X::AbstractMatrix) where {T}
    ps = collect(KernelFunctions.opt_params(kernel.kernel))
    return [kernelderivative(kernel,ps,ps[i],i,X) for i in 1:length(ps)]
end

function kernelderivative(kernel::KernelWrapper,X::AbstractMatrix,Y::AbstractMatrix) where {T}
    ps = collect(KernelFunctions.opt_params(kernel.kernel))
    return [kernelderivative(kernel,ps,ps[i],i,X,Y) for i in 1:length(ps)]
end

function kerneldiagderivative(kernel::KernelWrapper,X::AbstractMatrix) where {T}
    ps = collect(KernelFunctions.opt_params(kernel.kernel))
    return [kerneldiagderivative(kernel,ps,ps[i],i,X) for i in 1:length(ps)]
end

## Take derivative of scalar hyperparameter ##
function kernelderivative(kernel::KernelWrapper,θ,θᵢ::Real,i::Int,X::AbstractMatrix)
    reshape(ForwardDiff.jacobian(x->begin
        newθ = [j==i ? first(x) : θ[j] for j in 1:length(θ)]
        kernelmatrix(KernelFunctions.duplicate(kernel.kernel,newθ),X,obsdim=1)
    end, [θᵢ])
        ,size(X,1),size(X,1))
end

function kernelderivative(kernel::KernelWrapper,θ,θᵢ::Real,i::Int,X::AbstractMatrix,Y::AbstractMatrix)
    reshape(ForwardDiff.jacobian(x->begin
        newθ = [j==i ? first(x) : θ[j] for j in 1:length(θ)]
        kernelmatrix(KernelFunctions.duplicate(kernel.kernel,newθ),X,Y,obsdim=1)
    end, [θᵢ])
        ,size(X,1),size(Y,1))
end

function kerneldiagderivative(kernel::KernelWrapper,θ,θᵢ::Real,i::Int,X::AbstractMatrix)
    reshape(ForwardDiff.jacobian(x->begin
        newθ = [j==i ? first(x) : θ[j] for j in 1:length(θ)]
        kerneldiagmatrix(KernelFunctions.duplicate(kernel.kernel,newθ),X,obsdim=1)
    end, [θᵢ])
        ,size(X,1))
end

## Take derivative of vector hyperparameter ##
function kernelderivative(kernel::KernelWrapper,θ,θᵢ::AbstractVector{<:Real},i::Int,X::AbstractMatrix)
    reshape.(eachcol(
        ForwardDiff.jacobian(x->begin
        newθ = [j==i ? x : θ[j] for j in 1:length(θ)] #Recreate a parameter vector
        kernelmatrix(KernelFunctions.duplicate(kernel.kernel,newθ),X,obsdim=1);
    end, θᵢ)
        ),size(X,1),size(X,1))
end

function kernelderivative(kernel::KernelWrapper,θ,θᵢ::AbstractVector{<:Real},i::Int,X::AbstractMatrix,Y::AbstractMatrix)
    reshape.(eachcol(
        ForwardDiff.jacobian(x->begin
        newθ = [j==i ? x : θ[j] for j in 1:length(θ)] #Recreate a parameter vector
        kernelmatrix(KernelFunctions.duplicate(kernel.kernel,newθ),X,Y,obsdim=1);
    end, θᵢ)
        ),size(X,1),size(Y,1))
end

function kerneldiagderivative(kernel::KernelWrapper,θ,θᵢ::AbstractVector{<:Real},i::Int,X::AbstractMatrix)
    reshape.(eachcol(
        ForwardDiff.jacobian(x->begin
        newθ = [j==i ? x : θ[j] for j in 1:length(θ)] #Recreate a parameter vector
        kerneldiagmatrix(KernelFunctions.duplicate(kernel.kernel,newθ),X,obsdim=1);
    end, θᵢ)
        ),size(X,1))
end

## Take derivative of fixed hyperparameter (i.e. when transform is immutable)##
function kernelderivative(kernel::KernelWrapper,θ,θᵢ::Nothing,i::Int,X::AbstractMatrix)
    return nothing
end

function kernelderivative(kernel::KernelWrapper,θ,θᵢ::Nothing,i::Int,X::AbstractMatrix,Y::AbstractMatrix)
    return nothing
end

function kerneldiagderivative(kernel::KernelWrapper,θ,θᵢ::Nothing,i::Int,X::AbstractMatrix)
    return nothing
end

## Derivative of chain transform parameters ##
function kernelderivative(kernel::KernelWrapper,θ,θ_chaintransform::AbstractVector,i::Int,X::AbstractMatrix)
    return [kernelderivative(kernel,ps,ps[i],i,θ_chaintransform[j],j,X) for j in 1:length(θ_chaintransform)]
end

function kernelderivative(kernel::KernelWrapper,θ,θ_chaintransform::AbstractVector,i::Int,X::AbstractMatrix,Y::AbstractMatrix)
    return [kernelderivative(kernel,ps,ps[i],i,θ_chaintransform[j],j,X,Y) for j in 1:length(θ_chaintransform)]
end

function kerneldiagderivative(kernel::KernelWrapper,θ,θ_chaintransform::AbstractVector,i::Int,X::AbstractMatrix)
    return [kerneldiagderivative(kernel,ps,ps[i],i,θ_chaintransform[j],j,X) for j in 1:length(θ_chaintransform)]
end

## Derivative of chain transform parameters (Real) ##
function kernelderivative(kernel::KernelWrapper,θ,θ_t::AbstractVector,i::Int,θ_tj::Real,j::Int,X::AbstractMatrix)
    reshape.(eachcol(
        ForwardDiff.jacobian(x->begin
        newθ_t = [m==j ? first(x) : θ_t[m] for m in 1:length(θ_t)]
        newθ = vcat([newθ_t],θ[2:end])
        kernelmatrix(KernelFunctions.duplicate(kernel.kernel,newθ),X,obsdim=1)
    end, [θ_tj])
        ),size(X,1),size(X,1))
end

function kernelderivative(kernel::KernelWrapper,θ,θ_t::AbstractVector,i::Int,θ_tj::Real,j::Int,X::AbstractMatrix,Y::AbstractMatrix)
    reshape.(eachcol(
        ForwardDiff.jacobian(x->begin
        newθ_t = [m==j ? first(x) : θ_t[m] for m in 1:length(θ_t)]
        newθ = vcat([newθ_t],θ[2:end])
        kernelmatrix(KernelFunctions.duplicate(kernel.kernel,newθ),X,Y,obsdim=1)
    end, [θ_tj])
        ),size(X,1),size(Y,1))
end

function kerneldiagderivative(kernel::KernelWrapper,θ,θ_t::AbstractVector,i::Int,θ_tj::Real,j::Int,X::AbstractMatrix)
    reshape.(eachcol(
        ForwardDiff.jacobian(x->begin
        newθ_t = [m==j ? first(x) : θ_t[m] for m in 1:length(θ_t)]
        newθ = vcat([newθ_t],θ[2:end])
        kerneldiagmatrix(KernelFunctions.duplicate(kernel.kernel,newθ),X,obsdim=1)
    end, [θ_tj])
        ),size(X,1))
end

## Derivative of chain transform parameters (Vector) ##
function kernelderivative(kernel::KernelWrapper,θ,θ_t::AbstractVector,i::Int,θ_tj::AbstractVector,j::Int,X::AbstractMatrix)
    reshape.(eachcol(
        ForwardDiff.jacobian(x->begin
        newθ_t = [m==j ? x : θ_t[m] for m in 1:length(θ_t)]
        newθ = vcat(newθ_t,θ[2:end])
        kernelmatrix(KernelFunctions.duplicate(kernel.kernel,newθ),X,obsdim=1);
    end, pt)
        ),size(X,1),size(X,1))
end

function kernelderivative(kernel::KernelWrapper,θ,θ_t::AbstractVector,i::Int,θ_tj::AbstractVector,j::Int,X::AbstractMatrix,Y::AbstractMatrix)
    reshape.(eachcol(
        ForwardDiff.jacobian(x->begin
        newθ_t = [m==j ? x : θ_t[m] for m in 1:length(θ_t)]
        newθ = vcat(newθ_t,θ[2:end])
        kernelmatrix(KernelFunctions.duplicate(kernel.kernel,newθ),X,Y,obsdim=1);
    end, pt)
        ),size(X,1),size(Y,1))
end

function kerneldiagderivative(kernel::KernelWrapper,θ,θ_t::AbstractVector,i::Int,θ_tj::AbstractVector,j::Int,X::AbstractMatrix)
    reshape.(eachcol(
        ForwardDiff.jacobian(x->begin
        newθ_t = [m==j ? x : θ_t[m] for m in 1:length(θ_t)]
        newθ = vcat(newθ_t,θ[2:end])
        kernelmatrix(KernelFunctions.duplicate(kernel.kernel,newθ),X,obsdim=1);
    end, pt)
        ),size(X,1))
end

## Derivative of chain transform parameters (immutable) ##
function kernelderivative(kernel::KernelWrapper,θ,θ_t::AbstractVector,i::Int,θ_tj::Nothing,j::Int,X::AbstractMatrix)
    return nothing
end

function kernelderivative(kernel::KernelWrapper,θ,θ_t::AbstractVector,i::Int,θ_tj::Nothing,j::Int,X::AbstractMatrix,Y::AbstractMatrix)
    return nothing
end

function kerneldiagderivative(kernel::KernelWrapper,θ,θ_t::AbstractVector,i::Int,θ_tj::Nothing,j::Int,X::AbstractMatrix)
    return nothing
end

function indpoint_derivative(kernel::AbstractKernelWrapper,Z::InducingPoints)
    reshape(ForwardDiff.jacobian(x->kernelmatrix(kernel,x,obsdim=1),Z),size(Z,1),size(Z,1),size(Z,1),size(Z,2))
end

function indpoint_derivative(kernel::AbstractKernelWrapper,X,Z::InducingPoints)
    reshape(ForwardDiff.jacobian(x->kernelmatrix(kernel,X,x),Z),size(X,1),size(Z,1),size(Z,1),size(Z,2))
end
