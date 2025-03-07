abstract type AbstractDataContainer end

nSamples(d::AbstractDataContainer) = d.nSamples
nDim(d::AbstractDataContainer) = d.nDim
nOutput(d::AbstractDataContainer) = 1

input(d::AbstractDataContainer) = d.X
output(d::AbstractDataContainer) = d.y

struct DataContainer{Tx<:Real,TX<:AbstractVector,Ty<:Real,TY<:AbstractVector} <:
       AbstractDataContainer
    X::TX # Feature vectors
    y::TY # Output (-1,1 for classification, real for regression, vector{vector} for multiclass)
    nSamples::Int # Number of samples
    nDim::Int # Number of features per sample
end

function wrap_data(X::TX, y::TY) where {TX,TY<:AbstractVector{<:Real}}
    length(y) == length(X) || error(
        "There is not the same number of samples in X ($(length(X))) and y ($(length(y)))",
    )
    Tx = eltype(first(X))
    Ty = eltype(first(y))
    return DataContainer{Tx,TX,Ty,TY}(X, y, length(X), length(first(X)))
end

function wrap_data(X::TX, y::TY) where {TX,TY<:AbstractVector}
    all(length.(y) .== length(X)) || error(
        "There is not the same number of samples in X ($(length(X))) and y ($(length.(y))))",
    )
    Tx = eltype(first(X))
    Ty = eltype(first(y))
    return DataContainer{Tx,TX,Ty,TY}(X, y, length(X), length(first(X)))
end

struct MODataContainer{Tx<:Real,TX<:AbstractVector,TY<:AbstractVector} <:
       AbstractDataContainer
    X::TX # Feature vectors
    y::TY # Output (-1,1 for classification, real for regression, matrix for multiclass)
    nSamples::Int # Number of samples
    nDim::Int # Number of features per sample
    nOutput::Int # Number of outputs
end

function wrap_modata(X::TX, y::TY) where {TX,TY<:AbstractVector}
    all(length.(y) .== length(X)) || error(
        "There is not the same number of samples in X ($(length(X))) and y ($(length.(y))))",
    )
    Tx = eltype(first(X))
    return MODataContainer{Tx,TX,TY}(X, y, length(X), length(first(X)), length(y))
end

nOutput(d::MODataContainer) = d.nOutput

function wrap_X(X::AbstractMatrix{T}, obsdim::Int=1) where {T<:Real}
    return KernelFunctions.vec_of_vecs(X; obsdim=obsdim), T
end

function wrap_X(X::AbstractVector{T}, ::Int=1) where {T<:Real}
    return X, T
end

function wrap_X(X::AbstractVector{<:AbstractVector{T}}, ::Int=1) where {T<:Real}
    return X, T
end

mutable struct OnlineDataContainer <: AbstractDataContainer
    X::AbstractVector # Feature vectors
    y::AbstractVector # Output (-1,1 for classification, real for regression, matrix for multiclass)
    nSamples::Int # Number of samples
    nDim::Int # Number of features per sample
    function OnlineDataContainer()
        return new()
    end
end

function wrap_data!(data::OnlineDataContainer, X::AbstractVector, y::AbstractVector)
    data.X = X
    data.y = y
    data.nSamples = size(X, 1)
    return data.nDim = size(first(X), 1)
end
