using AugmentedGaussianProcesses
using Test
using Random: seed!
seed!(42)

include("testingtools.jl")

AGP.setadbackend(:reverse_diff)
# Global flags for the tests
@testset "AugmentedGaussianProcesses.jl tests" begin
    @testset "Functions" begin
        for f in readdir(joinpath(@__DIR__, "functions"))
            include(joinpath("functions",f))
        end
    end
    @testset "Hyperparameters" begin

    end
    @testset "Inducing Points" begin
        for f in readdir(joinpath(@__DIR__, "inducingpoints"))
            include(joinpath("inducingpoints", f))
        end
    end
    @testset "Inference" begin
        for f in readdir(joinpath(@__DIR__, "inference"))
            include(joinpath("inference", f))
        end
    end
    @testset "Likelihoods" begin
        include("test_likelihoods.jl")
    end
    @testset "Models" begin
        for f in readdir(joinpath(@__DIR__, "models"))
            include(joinpath("models",f))
        end
    end
    @testset "Prior" begin
        for f in readdir(joinpath(@__DIR__, "prior"))
            include(joinpath("prior",f))
        end
    end
    include("training.jl")
    include("onlinetraining.jl")
    include("predictions.jl")
end
