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

end
