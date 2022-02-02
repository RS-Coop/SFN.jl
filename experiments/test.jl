using Flux
using ForwardDiff: partials, Dual
using Zygote: pullback
using CUDA
using LinearAlgebra
using Statistics: mean

if Flux.use_cuda[] == false
    ErrorException("Not using GPU.")
end

CUDA.allowscalar(false)

#=
In-place hvp operator compatible with Krylov.jl
=#
mutable struct HvpOperator{F, T, I}
	f::F
	x::AbstractArray{T, 1}
	dualCache1::AbstractArray{Dual{Nothing, T, 1}}
	size::I
	nProd::I
end

function HvpOperator(f, x::AbstractVector)
	dualCache1 = Dual.(x, similar(x))
	return HvpOperator(f, x, dualCache1, size(x, 1), 0)
end

Base.eltype(op::HvpOperator{F, T, I}) where{F, T, I} = T
Base.size(op::HvpOperator) = (op.size, op.size)

function LinearAlgebra.mul!(result::AbstractVector, op::HvpOperator, v::AbstractVector)
	op.nProd += 1

	op.dualCache1 .= Dual.(op.x, v)
	val, back = pullback(op.f, op.dualCache1)

	result .= partials.(back(one(val))[1], 1)
end

_relu(x) = max.(0,x)
_logsoftmax(x) = x .- log.(sum(exp.(x)))
_logitcrossentropy(ŷ, y) = mean(.-sum(y.*_logsoftmax(ŷ)))

data = randn(10, 4) |> gpu
labels = Flux.onehotbatch(rand(1:10, 4), 1:10) |> gpu

data = data[Tuple(Colon() for i in 1:ndims(data)-1)..., [1,3]]
labels = labels[:, [1,3]]

exit()

model = Dense(10, 10)∘_relu∘Dense(10,10) |> gpu

ps, re = Flux.destructure(model)
f(θ) = _logitcrossentropy(re(θ)(data), labels)

Hop = HvpOperator(f, ps)

v, res = copy(ps), similar(ps)

LinearAlgebra.mul!(res, Hop, v)
