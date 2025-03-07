@testset "AffineMean" begin
    N = 20
    D = 3
    x = rand()
    X = rand(N,D)
    b = randn()
    w = randn(D)
    μ₀ = AffineMean(w,b,opt=Descent(1.0))
    @test μ₀ isa AffineMean{Float64, Vector{Float64}}
    @test_nowarn AffineMean(3)(X)
    @test repr("text/plain", μ₀) == "Affine Mean Prior (size(w) = $D, b = $b)"
    @test μ₀(X) == X*w .+ b
    @test_throws ErrorException AffineMean(4)(X)
   global g = Zygote.gradient(μ₀) do m
        sum(m(X))
    end
    AGP.update!(μ₀, first(g))
    @test all(μ₀.w .== (w + first(g).w))
    @test first(μ₀.b) == b + first(g).b[1]
end
