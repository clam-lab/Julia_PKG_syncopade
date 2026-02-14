module Julia_GeneralObjectiveFunction

using LinearAlgebra

export ObjectiveParams, objective, objective_from_string

Base.@kwdef struct ObjectiveParams
    n::Int = 2048
    k_max::Int = 120
    tol::Float64 = 1.0e-6
    ω::Float64 = 0.35
    a0::Float64 = 1.0
    a1::Float64 = 0.5
    beta0::Float64 = 0.2
    beta1::Float64 = 0.06
    ksig::Float64 = 4.0
    W::Union{Nothing, Matrix{Float64}} = nothing
    B::Union{Nothing, Matrix{Float64}} = nothing
    b0::Union{Nothing, Vector{Float64}} = nothing
    u0::Union{Nothing, Vector{Float64}} = nothing
end

"""
    objective(x; p=ObjectiveParams())

General objective function prototype for distributed evaluation.
Returns only the scalar objective value `f(x) = ||F(u*(x), x)||^2`.
"""
function objective(x::AbstractVector; p::ObjectiveParams=ObjectiveParams())
    n = p.n
    k_max = p.k_max
    tol = p.tol
    ω = p.ω
    a0 = p.a0
    a1 = p.a1
    β0 = p.beta0
    β1 = p.beta1
    ksig = p.ksig

    d = length(x)
    u = _init_u(p, n)
    a = Vector{Float64}(undef, n)
    b = Vector{Float64}(undef, n)
    r = Vector{Float64}(undef, n)
    Lu = Vector{Float64}(undef, n)

    _fill_a!(a, x, p, a0, a1)
    β = β0 + β1 * _sigmoid(ksig * (sum(x) / max(d, 1)))
    _fill_b!(b, x, p)

    f = Inf
    for _ in 1:k_max
        _apply_laplacian!(Lu, u)
        @inbounds for i in 1:n
            r[i] = Lu[i] + a[i] * u[i] + β * tanh(u[i]) - b[i]
        end
        f = dot(r, r)
        if sqrt(f / n) < tol
            return f
        end

        # Diagonal-approximate damped Newton step for stable convergence.
        @inbounds for i in 1:n
            t = tanh(u[i])
            denom = 2.0 + a[i] + β * (1.0 - t * t) + 1.0e-8
            u[i] -= ω * (r[i] / denom)
        end
    end

    return f
end

"""
    objective_from_string(x_str::String; p=ObjectiveParams())

Syncopade-friendly wrapper: parse a string-encoded vector and evaluate `objective`.

Accepted formats:
- `"[0.1, 0.2, 0.3]"`
- `"0.1,0.2,0.3"`
"""
function objective_from_string(x_str::String; p::ObjectiveParams=ObjectiveParams())
    x = _parse_vector_arg(x_str)
    return objective(x; p=p)
end

function _parse_vector_arg(x_str::String)::Vector{Float64}
    s = strip(x_str)
    if startswith(s, "[") && endswith(s, "]")
        s = strip(s[2:end-1])
    end
    isempty(s) && throw(ArgumentError("x is empty"))

    parts = split(s, ',')
    x = Float64[]
    for p in parts
        v = strip(p)
        isempty(v) && continue
        push!(x, parse(Float64, v))
    end

    isempty(x) && throw(ArgumentError("failed to parse x from: $x_str"))
    return x
end

_sigmoid(z) = inv(1 + exp(-clamp(z, -40.0, 40.0)))

function _init_u(p::ObjectiveParams, n::Int)
    u0 = p.u0
    if u0 === nothing
        return zeros(Float64, n)
    end
    return collect(Float64, u0)
end

function _fill_a!(a::AbstractVector{Float64}, x::AbstractVector, p::ObjectiveParams, a0::Real, a1::Real)
    n = length(a)
    W = p.W
    if W === nothing
        d = length(x)
        @inbounds for i in 1:n
            s = 0.0
            for j in 1:d
                s += sin(0.013 * i * j) * x[j]
            end
            a[i] = a0 + a1 * _sigmoid(s)
        end
    else
        @inbounds for i in 1:n
            s = 0.0
            for j in eachindex(x)
                s += W[i, j] * x[j]
            end
            a[i] = a0 + a1 * _sigmoid(s)
        end
    end
    return a
end

function _fill_b!(b::AbstractVector{Float64}, x::AbstractVector, p::ObjectiveParams)
    n = length(b)
    d = length(x)
    b0 = p.b0
    B = p.B

    if b0 === nothing
        @inbounds for i in 1:n
            b[i] = 0.1 * cos(0.01 * i)
        end
    else
        @inbounds for i in 1:n
            b[i] = b0[i]
        end
    end

    if B === nothing
        @inbounds for i in 1:n
            for j in 1:d
                b[i] += 0.02 * sin(0.017 * i * j) * x[j]
            end
        end
    else
        @inbounds for i in 1:n
            for j in eachindex(x)
                b[i] += B[i, j] * x[j]
            end
        end
    end
    return b
end

function _apply_laplacian!(y::AbstractVector{Float64}, u::AbstractVector{Float64})
    n = length(u)
    @inbounds begin
        y[1] = 2.0 * u[1] - u[2]
        for i in 2:(n - 1)
            y[i] = 2.0 * u[i] - u[i - 1] - u[i + 1]
        end
        y[n] = 2.0 * u[n] - u[n - 1]
    end
    return y
end


end # module Julia_GeneralObjectiveFunction
