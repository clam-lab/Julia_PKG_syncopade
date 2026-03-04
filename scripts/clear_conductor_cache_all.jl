#!/usr/bin/env julia

using Sockets

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

const DEFAULT_CONDUCTOR_IP = "192.168.12.4"
const DEFAULT_CONDUCTOR_PORT = 9004

function last_octet(ip::String)::Int
    parts = split(ip, ".")
    if length(parts) != 4
        throw(ArgumentError("Invalid IPv4 address: $ip"))
    end
    return parse(Int, parts[end])
end

function usage()
    println("Usage: julia scripts/clear_conductor_cache_all.jl [conductor_ip] [conductor_port]")
    println("  conductor_ip   default: $(DEFAULT_CONDUCTOR_IP)")
    println("  conductor_port default: $(DEFAULT_CONDUCTOR_PORT) when conductor_ip omitted")
    println("                  if conductor_ip is given and conductor_port omitted: 9000 + last octet")
end

if any(a -> a == "-h" || a == "--help", ARGS)
    usage()
    exit(0)
end

conductor_ip = length(ARGS) >= 1 ? ARGS[1] : DEFAULT_CONDUCTOR_IP
conductor_port = if length(ARGS) >= 2
    parse(Int, ARGS[2])
elseif length(ARGS) == 1
    9000 + last_octet(conductor_ip)
else
    DEFAULT_CONDUCTOR_PORT
end

println("conductor = ", conductor_ip, ":", conductor_port)

summary = clear_conductor_node_caches(conductor_ip; conductor_port=conductor_port)

println(
    "CACHE_CLEAR_ALL summary: total_nodes=", summary.total_nodes,
    " success_nodes=", summary.success_nodes,
    " failed_nodes=", summary.failed_nodes,
    " cleared_functions=", summary.cleared_functions
)

if summary.failed_nodes > 0
    exit(2)
end
