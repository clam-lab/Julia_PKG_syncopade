using Test, Sockets, UUIDs
include(joinpath(@__DIR__, "..", "syncopadeServer.jl"))

function listener_request(handle, payload; timeout=10.0)
    socket = TCPSocket()
    timer = Timer(timeout) do _
        close(socket)
    end
    try
        connect(socket, handle.bind_ip, handle.port)
        println(socket, payload * "|" * checksum_hex(payload))
        return readline(socket)
    finally
        close(timer)
        close(socket)
    end
end

function receive_listener_callback(listener; ack=false)
    socket = nothing
    timer = Timer(15) do _
        close(listener)
        socket === nothing || close(socket)
    end
    try
        socket = accept(listener)
        row = readline(socket)
        valid, payload = checksum(row)
        valid || error("invalid notification checksum")
        if ack
            println(socket, "OK|" * checksum_hex("OK"))
        end
        return String.(split(payload, '|'))
    finally
        close(timer)
        socket === nothing || close(socket)
    end
end

function wait_listener_state(handle, state; timeout=10.0)
    timedwait(() -> runtime_snapshot(handle.supervisor.runtime).state == state, timeout; pollint=0.01) == :ok ||
        error("listener did not reach $state; $(runtime_snapshot(handle.supervisor.runtime))")
end

function listener_task_payload(callback, function_name, args=String[]; conductor=nothing, task_id="",
    fixture=joinpath(@__DIR__, "fixtures", "listener_probe.jl"))
    fields = vcat(["127.0.0.1", string(getsockname(callback)[2]), "$fixture:ListenerProbe:$function_name"], args)
    if conductor !== nothing
        append!(fields, [META_TASK_ID_PREFIX * task_id, META_CONDUCTOR_IP_PREFIX * "127.0.0.1",
            META_CONDUCTOR_PORT_PREFIX * string(getsockname(conductor)[2])])
    end
    return join(fields, '|')
end

function normal_listener_stderr(text)
    all(split(text, '\n'; keepempty=false)) do line
        line == "WARNING: replacing module ListenerProbe." ||
            line == "Precompiling packages..." ||
            occursin(r"^\s*\d+(?:\.\d+)? ms\s+✓ (?:UUIDs|ReloadProbe)(?: \(serial\))?$", line) ||
            occursin(r"^  \d+ dependenc(?:y|ies) successfully precompiled in \d+ seconds$", line)
    end
end

function with_test_listener(test; extra_env=Dict{String,String}(), stderr_check=nothing, config_options...)
    mktempdir() do dir
        audit = IOBuffer()
        output = open(joinpath(dir, "stdout"), "w+")
        errors = open(joinpath(dir, "stderr"), "w+")
        separator = Sys.iswindows() ? ';' : ':'
        fixture_env = Dict(
            "JULIA_LOAD_PATH" => join([joinpath(@__DIR__, "fixtures", "package_reload", "v1"), "@", "@stdlib"], separator),
            "JULIA_DEPOT_PATH" => joinpath(dir, "depot"),
        )
        config = ExecutorLaunchConfig(; env=merge(Dict(ENV), fixture_env, extra_env), config_options...)
        handle = syncopade_server(ip"127.0.0.1", 0; config, audit, output, errors)
        owned = nothing
        try
            wait_listener_state(handle, :idle)
            owned = handle.supervisor.child
            test(handle, dir, audit)
        finally
            final_child = handle.supervisor.child
            stopped = stop_listener!(handle)
            @test stopped.ok
            @test owned === nothing || process_exited(owned.process)
            @test final_child === nothing || process_exited(final_child.process)
            @test !isopen(handle.socket)
            close(output)
            close(errors)
        end
        rebound = listen(ip"127.0.0.1", handle.port)
        @test isopen(rebound)
        close(rebound)
        text = read(joinpath(dir, "stderr"), String)
        if stderr_check === nothing
            @test normal_listener_stderr(text)
        else
            @test stderr_check(text, owned)
        end
    end
end
