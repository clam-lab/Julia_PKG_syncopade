using Sockets

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

function last_octet(ip::String)::Int
    parts = split(ip, ".")
    return parse(Int, parts[end])
end

conductor_ip = length(ARGS) >= 1 ? ARGS[1] : string(getipaddr())
conductor_port = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : (9000 + last_octet(conductor_ip))

println("conductor = ", conductor_ip, ":", conductor_port)
show_available_nodes(conductor_ip, conductor_port)
