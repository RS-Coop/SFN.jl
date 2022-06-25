#=
Author: Cooper Simpson

All functionality to interact with Flux.jl and support R-SFN optimizer
=#
using .Flux
using Zygote: pullback

#=
Optimizer for stochastic R-SFN.
=#
Base.@kwdef mutable struct StochasticRSFN
    optimizer::RSFN{Float32}
    sub_sample::Float32
end

#=
Constructor.

Input:
    dim :: dimension of parameters
    sub_sample :: hessian sub sample factor in (0,1] (optional)
=#
function StochasticCubicNewton(dim::Int, sub_sample::Float32=0.1)
    if !((0.0 < sub_sample) && (sub_sample <= 1.0))
        throw(ArgumentError("Hessian sample factor not in range (0,1]."))
    end

    return StochasticrRSFN(RSFNOptimizer{Float32}(dim), sub_sample)
end

#=
Custom Flux training function for a StochasticRSFN optimizer

Input:
    f :: model + loss function
    ps :: model params
    trainLoader :: training data
    opt :: cubic newton optimizer
=#
function Flux.Optimise.train!(f::Function, ps::T, trainLoader, opt::StochasticRSFN) where T<:AbstractVector
    grads = similar(ps)

    #TODO: allocate spsace for subsamples only once
    # sampleSize = opt.hessianSampleFactor*n
    # subX =
    # subY =

    @inbounds for (X, Y) in trainLoader
        #build hvp operator using subsampled batch
        n = size(X, ndims(X))

        idx = rand(1:n, ceil(Int, opt.hessianSampleFactor*n))

        #inplace view
        # subX = selectdim(X, ndims(X), idx)
        # subY = selectdim(Y, ndims(Y), idx)

        #copy
        subX = X[Tuple([Colon() for i in 1:ndims(X)-1])..., idx]
        subY = Y[:, idx]

        # update!(opt.Hop, θ -> f(θ, subX, subY), ps)
        Hop = HvpOperator(θ -> f(θ, subX, subY), ps)

        #compute gradients
        loss, back = pullback(θ -> f(θ, X, Y), ps)
        grads .= back(one(loss))[1]

        #make an update step
        @time step!(opt.optimizer, θ -> f(θ, X, Y), ps, grads, Hop)

        opt.log.hvps += Hop.nProd
    end
end

#=
Flatten a models parameters into a single vector, and then create a new model
that references these flattened parameters.

NOTE: Assumes everything is trainable

Input:
    model :: Flux model
=#
function make_flat(model)
    #grab all the paramaters
    ps = AbstractVector[]
    fmap(model) do p
        p isa AbstractArray && push!(arrays, vec(p))
        return x
    end
    flat_ps = reduce(vcat, ps)

    #Make a new model with views into flattened parameters
    offset = Ref(0)
    out = fmap(model) do p
        p isa AbstractArray || return p
        y = view(flat_ps, offset[] .+ (1:length(p)))
        offset[] += length(p)
        return reshape(y, size(p))
    end

    #return flattened parameters and new model
    return flat, out
end
