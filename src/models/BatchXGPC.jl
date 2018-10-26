"Gaussian Process Classifier with Logistic Likelihood"
mutable struct BatchXGPC <: FullBatchModel
    @commonfields
    @functionfields
    @gaussianparametersfields
    @kernelfields
    c::Vector{Float64}
    θ::Vector{Float64}
    "BatchXGPC Constructor"
    function BatchXGPC(X::AbstractArray,y::AbstractArray;Autotuning::Bool=false,optimizer::Optimizer=Adam(),nEpochs::Integer = 200,
                                    kernel=0,noise::Float64=1e-3,AutotuningFrequency::Integer=1,
                                    ϵ::Float64=1e-5,μ_init::Array{Float64,1}=[0.0],verbose::Integer=0)
            this = new(X,y)
            this.ModelType = XGPC
            this.Name = "Gaussian Process Classifier with Logistic Likelihood"
            initCommon!(this,X,y,noise,ϵ,nEpochs,verbose,Autotuning,AutotuningFrequency,optimizer);
            initFunctions!(this);
            initKernel!(this,kernel);
            initGaussian!(this,μ_init);
            this.c = abs.(rand(this.nSamples))*2;
            this.θ = zero(this.c)
            return this;
    end
    "Empty constructor for loading models"
    function BatchXGPC()
        this = new()
        this.ModelType = XGPC
        this.Name = "Gaussian Process Classifier with Logistic Likelihood"
        initFunctions!(this)
        return this;
    end
end