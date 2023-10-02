#=
Author: Cooper Simpson

SFN optimizer.
=#

using FastGaussQuadrature: gausslaguerre
using Krylov: CgLanczosShiftSolver, cg_lanczos_shift!
using Zygote: pullback

#=
SFN optimizer struct.
=#
mutable struct SFNOptimizer{T1<:Real, T2<:AbstractFloat, S<:AbstractVector{T2}}
    M::T1 #hessian lipschitz constant
    ϵ::T2#regularization minimum
    quad_nodes::S #quadrature nodes
    quad_weights::S #quadrature weights
    krylov_solver::CgLanczosShiftSolver #krylov inverse mat vec solver
    itmax::Int
end

#=
Outer constructor

NOTE: FGQ cant currently handle anything other than Float64

Input:
    dim :: dimension of parameters
    type :: parameter type
    M :: hessian lipschitz constant
    ϵ :: regularization minimum
    quad_order :: number of quadrature nodes
=#
function SFNOptimizer(dim::Int, type::Type{<:AbstractVector{T2}}=Vector{Float64}; M::T1=1, ϵ::T2=eps(Float64), quad_order::Int=20) where {T1<:Real, T2<:AbstractFloat}
    #quadrature
    nodes, weights = gausslaguerre(quad_order, 0.0, reduced=true)

    if size(nodes, 1) < quad_order
        quad_order = size(nodes, 1)
        println("Quadrature weight precision reached, using $(size(nodes,1)) quadrature locations.")
    end

    #krylov solver
    solver = CgLanczosShiftSolver(dim, dim, quad_order, type)

    #=
    NOTE: Performing some extra global operations here.
    - Integral constant
    - Rescaling weights
    - Squaring nodes
    =#
    @. weights = (2/pi)*weights*exp(nodes)
    @. nodes = nodes^2

    #max number of Krylov iterations
    # itmax = round(Int, sqrt(dim))
    itmax = 2*dim

    return SFNOptimizer(M, ϵ, nodes, weights, solver, itmax)
end

#=
Repeatedly applies the SFN iteration to minimize the function.

Input:
    opt :: SFNOptimizer
    x :: initialization
    f :: scalar valued function
    itmax :: maximum iterations
    linesearch :: whether to use step-size with linesearch
=#
function minimize!(opt::SFNOptimizer, x::S, f::F; itmax::Int=1000, linesearch::Bool=false) where {T<:AbstractFloat, S<:AbstractVector{T}, F}
    fvec = []

    grads = similar(x)
    Hv = RHvpOperator(f, x)

    for i = 1:itmax
        #construct gradient and hvp operator
        fval, back = pullback(f, x)
        grads .= back(one(fval))[1]

        push!(fvec, fval)

        #iterate
        stationary = step!(opt, x, f, grads, Hv, linesearch)

        if stationary
            break
        end

        update!(Hv, x)
    end

    return fvec
end

#=
Repeatedly applies the SFN iteration to minimize the function.

Input:
    opt :: SFNOptimizer
    x :: initialization
    f :: scalar valued function
    g! :: inplace gradient function of f
    H :: hvp generator
    itmax :: maximum iterations
    linesearch :: whether to use step-size with linesearch
=#
function minimize!(opt::SFNOptimizer, x::S, f::F1, g!::F2, H::L; itmax::Int=1000, linesearch::Bool=false) where {T<:AbstractFloat, S<:AbstractVector{T}, F1, F2, L}
    fvec = []

    grads = similar(x)
    Hv = LHvpOperator(H, x)

    for i = 1:itmax
        #compute loss, gradient, and update Hv
        fval = f(x)
        g!(x, grads)

        push!(fvec, fval)

        #iterate
        stationary = step!(opt, x, f, grads, Hv, linesearch)

        if stationary
            break
        end

        update!(Hv, x)
    end

    return fvec
end

#=
Computes an update step according to the shifted Lanczos-CG update rule.

Input:
    opt :: SFNOptimizer
    x :: current iterate
    f :: scalar valued function
    grads :: function gradients
    Hv :: hessian operator
=#
function step!(opt::SFNOptimizer, x::S, f::F, grads::S, Hv::HvpOperator, linesearch::Bool=false) where {T<:AbstractFloat, S<:AbstractVector{T}, F}
    #compute regularization
    g_norm = norm(grads)

    if g_norm <= sqrt(eps(T))
        return true
    end

    λ = opt.M*g_norm + opt.ϵ

    #compute shifts
    shifts = opt.quad_nodes .+ λ

    #compute CG Lanczos quadrature integrand ((tᵢ²+λₖ)I+Hₖ²)⁻¹gₖ
    cg_lanczos_shift!(opt.krylov_solver, Hv, grads, shifts, itmax=opt.itmax)

    #evaluate integral and update
    if linesearch
        p = similar(x)

        @inbounds for i = 1:size(shifts, 1)
            p .-= opt.quad_weights[i]*opt.krylov_solver.x[i]
        end

        x .= search!(p, x, f, g_norm)
    else
        @inbounds for i = 1:size(shifts, 1)
            x .-= opt.quad_weights[i]*opt.krylov_solver.x[i]
        end
    end

    # println(opt.krylov_solver.stats.status)

    return false
end
