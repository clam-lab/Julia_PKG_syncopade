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

conductor_server()
if get(ENV, "SYNCOPADE_TEST_MONITOR", "false") == "true"
    @async monitor_nodes(interval=0.05)
end
while !eof(stdin)
    strip(readline(stdin)) == "q" && break
end
stop_conductor_log_writer!()
