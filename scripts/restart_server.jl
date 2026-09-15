include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

function restart_server_cli(args=ARGS)::Int
    if args == ["--help"] || args == ["-h"]
        println("Usage: julia --project=. scripts/restart_server.jl IP PORT [--timeout SECONDS]")
        return 0
    end
    if !(length(args) == 2 || (length(args) == 4 && args[3] == "--timeout"))
        println("Usage: julia --project=. scripts/restart_server.jl IP PORT [--timeout SECONDS]")
        return 64
    end
    endpoint = args[1]
    port = tryparse(Int, args[2])
    timeout = length(args) == 4 ? tryparse(Float64, args[4]) : 60.0
    if port === nothing || !(0 < port <= 65535) || timeout === nothing || !isfinite(timeout) || timeout <= 0
        println("Invalid port or timeout")
        return 64
    end
    try
        parse(IPAddr, endpoint)
    catch
        println("An explicit IP address is required")
        return 64
    end
    println("endpoint=$endpoint:$port")
    before = try
        query_server_runtime(endpoint; server_port=port, timeout=min(5.0, timeout))
    catch error
        println("status=query_failed reason=", sprint(showerror, error))
        return 3
    end
    println("old_listener_id=$(before.listener_id) old_server_id=$(before.server_id) state=$(before.state)")
    result = restart_server_executor(endpoint; server_port=port,
        expected_listener_id=before.listener_id, expected_server_id=before.server_id, timeout)
    println("status=$(result.status) reason=$(result.reason)")
    if result.runtime !== nothing
        info = result.runtime
        println("listener_id=$(info.listener_id) server_id=$(info.server_id) state=$(info.state) ready=$(info.ready) listener_pid=$(info.listener_pid) server_pid=$(info.server_pid)")
    end
    result.status == :success && return 0
    result.status in (:unknown, :transport_error) && return 3
    return 2
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(restart_server_cli())
end
