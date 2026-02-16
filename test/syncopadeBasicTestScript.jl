# Basic test script for end-to-end Syncopade system testing.

module syncopadeBasicTestScript

"""
    mock_objective_product(x, p)

Mock numerical objective:
- `x`: design-variable vector
- `p`: parameter vector

Returns the product of all elements in `x` and `p`.
"""
function mock_objective_product(x::AbstractVector, p::AbstractVector)
    return prod(x) * prod(p)
end

function _parse_vector_arg(v_str::String)::Vector{Float64}
    s = strip(v_str)
    if startswith(s, "[") && endswith(s, "]")
        s = strip(s[2:end-1])
    end
    isempty(s) && throw(ArgumentError("vector string is empty"))

    parts = split(s, ',')
    v = Float64[]
    for part in parts
        token = strip(part)
        isempty(token) && continue
        push!(v, parse(Float64, token))
    end
    isempty(v) && throw(ArgumentError("failed to parse vector: $v_str"))
    return v
end

"""
    mock_objective_product_from_string(x_str, p_str) -> String

Server-call entrypoint for Syncopade protocol:
- input: two String arguments
- output: String result
"""
function mock_objective_product_from_string(x_str::String, p_str::String)::String
    println("[syncopadeBasicTestScript] entered mock_objective_product_from_string")
    println("[syncopadeBasicTestScript] x_str=", x_str, " p_str=", p_str)
    x = _parse_vector_arg(x_str)
    p = _parse_vector_arg(p_str)
    println("[syncopadeBasicTestScript] parsed lengths: x=", length(x), " p=", length(p))
    value = mock_objective_product(x, p)
    println("[syncopadeBasicTestScript] computed value=", value)
    return string(value)
end

# Simple alias entrypoint for Syncopade tests.
function test(x_str::String, p_str::String)::String
    return mock_objective_product_from_string(x_str, p_str)
end

end
