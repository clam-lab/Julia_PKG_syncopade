include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

function restart_conductor_usage()
    println("Usage: julia --project=. scripts/restart_conductor_servers.jl IP PORT [--operation-id UUID] [--status] [--timeout SECONDS]")
end

function restart_conductor_cli(args=ARGS)::Int
    if args in (["--help"], ["-h"])
        restart_conductor_usage()
        return 0
    end
    length(args) >= 2 || (restart_conductor_usage(); return 64)
    ip = args[1]
    port = tryparse(Int, args[2])
    id = nothing
    status_only = false
    timeout = 90.0
    index = 3
    while index <= length(args)
        option = args[index]
        if option == "--status"
            status_only && return 64
            status_only = true
        elseif option in ("--operation-id", "--timeout") && index < length(args)
            index += 1
            if option == "--operation-id"
                id === nothing || return 64
                id = args[index]
            else
                parsed = tryparse(Float64, args[index])
                parsed === nothing && return 64
                timeout = parsed
            end
        else
            restart_conductor_usage()
            return 64
        end
        index += 1
    end
    port !== nothing && 0 < port <= 65535 && isfinite(timeout) && timeout > 0 || return 64
    try
        parse(IPAddr, ip)
    catch
        return 64
    end
    status_only && id === nothing && return 64
    id === nothing && (id = string(uuid4()))
    valid_management_uuid(id) || return 64
    println("conductor=$ip:$port operation_id=$id")
    result = try
        if status_only
            query_conductor_executor_restart(ip; conductor_port=port, operation_id=id, timeout=min(5.0, timeout))
        else
            started = start_conductor_executor_restart(ip; conductor_port=port, operation_id=id, timeout=min(5.0, timeout))
            if started.state in (:running, :outcome_unknown)
                wait_conductor_executor_restart(ip; conductor_port=port, operation_id=id, timeout)
            else
                started
            end
        end
    catch error
        println("state=query_failed reason=", sprint(showerror, error))
        return 3
    end
    println("operation_id=$(result.operation_id) state=$(result.state) reason=$(result.reason)")
    for node in result.nodes
        outcome = node.result
        current = outcome.runtime === nothing ? "unconfirmed" : "$(outcome.runtime.listener_id)/$(outcome.runtime.server_id) state=$(outcome.runtime.state)"
        println("node=$(node.name) endpoint=$(node.ip):$(node.port) status=$(outcome.status) old=$(outcome.old_listener_id)/$(outcome.old_server_id) new=$current reason=$(outcome.reason)")
    end
    if result.summary !== nothing
        summary = result.summary
        println("total_nodes=$(summary.total_nodes) success_nodes=$(summary.success_nodes) failed_nodes=$(summary.failed_nodes) overall_success=$(summary.overall_success)")
        return summary.overall_success ? 0 : 2
    end
    result.state == :busy && return 2
    result.state == :running && return 4
    return 3
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(restart_conductor_cli())
end
