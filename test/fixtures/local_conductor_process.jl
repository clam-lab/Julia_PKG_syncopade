# Test-only process: never use configured LAN nodes or the repository log.
using Sockets
include(joinpath(@__DIR__, "..", "..", "syncopadeConductor.jl"))
const TEST_CONDUCTOR_PORT = parse(Int, ARGS[1])
const TEST_CONDUCTOR_NODES = let nodes = NODES[]
    for entry in split(get(ENV, "SYNCOPADE_TEST_NODES", ""), ';'; keepempty=false)
        fields = split(entry, ','; limit=3)
        push!(nodes, NODES(String(fields[1]), parse(Int, fields[2]), String(fields[3])))
    end
    nodes
end
preferred_local_ip(; prefix="") = ip"127.0.0.1"
conductor_port() = TEST_CONDUCTOR_PORT
geneAvailableNodeList() = copy(TEST_CONDUCTOR_NODES)
configured_node_entries() = [(ip=node.IP, port=node.port, name=node.name) for node in TEST_CONDUCTOR_NODES]

if haskey(ENV, "SYNCOPADE_TEST_REFRESH_ENTERED")
    function refresh_states_until_idle!(nodes::Vector{NODES}; timeout=DEFAULT_STATUS_TIMEOUT)::Bool
        for observation in probe_nodes_parallel(nodes; timeout=max(timeout, 1.0))
            apply_node_observation!(observation; source=:test_refresh)
        end
        write(ENV["SYNCOPADE_TEST_REFRESH_ENTERED"], "observed")
        while !isfile(ENV["SYNCOPADE_TEST_REFRESH_RELEASE"])
            sleep(0.01)
        end
        return any(node -> get_node_state(node) == NODE_IDLE, nodes)
    end
end

conductor_server()
if get(ENV, "SYNCOPADE_TEST_MONITOR", "false") == "true"
    @async begin
        gate = get(ENV, "SYNCOPADE_TEST_MONITOR_GATE", "")
        while !isempty(gate) && !isfile(gate)
            sleep(0.01)
        end
        monitor_nodes(interval=0.05)
    end
end
while !eof(stdin)
    strip(readline(stdin)) == "q" && break
end
stop_conductor_log_writer!()
