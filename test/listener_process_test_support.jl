function start_listener_process(dir; extra_env=Dict{String,String}())
    output = open(joinpath(dir, "listener.stdout"), "w+")
    errors = open(joinpath(dir, "listener.stderr"), "w+")
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) --threads=4 $(joinpath(@__DIR__, "fixtures", "local_listener_process.jl"))`
    separator = Sys.iswindows() ? ';' : ':'
    env = merge(Dict("JULIA_DEPOT_PATH" => joinpath(dir, "depot"),
        "JULIA_LOAD_PATH" => join([joinpath(@__DIR__, "fixtures", "package_reload", "v1"), "@", "@stdlib"], separator)), extra_env)
    process = open(pipeline(addenv(command, env); stderr=errors), "w", output)
    port = 0
    ready = timedwait(20; pollint=0.05) do
        process_exited(process) && return true
        matched = match(r"LOCAL_LISTENER_PORT=(\d+)\n", read(joinpath(dir, "listener.stdout"), String))
        matched === nothing && return false
        port = parse(Int, matched[1])
        try
            return Syncopade.query_server_runtime("127.0.0.1"; server_port=port, timeout=0.5).ready
        catch
            return false
        end
    end
    if ready != :ok || process_exited(process)
        process_running(process) && kill(process, Base.SIGKILL)
        wait(process)
        close(output)
        close(errors)
        error("local listener failed: $(read(joinpath(dir, "listener.stderr"), String))")
    end
    return (; process, port, bind_ip=ip"127.0.0.1", output, errors, dir)
end

function stop_listener_process(child)
    if process_running(child.process)
        write(child.process, "q\n")
        flush(child.process)
        close(child.process.in)
        if timedwait(() -> process_exited(child.process), 20; pollint=0.01) != :ok
            kill(child.process, Base.SIGKILL)
            wait(child.process)
            error("local listener did not stop normally")
        end
    end
    wait(child.process)
    close(child.output)
    close(child.errors)
    @test child.process.exitcode == 0
    text = read(joinpath(child.dir, "listener.stderr"), String)
    normal_listener_stderr(text) || println("UNEXPECTED_LISTENER_STDERR ", repr(text))
    @test normal_listener_stderr(text)
    @test occursin("LOCAL_LISTENER_STOP ok=true", read(joinpath(child.dir, "listener.stdout"), String))
    rebound = listen(ip"127.0.0.1", child.port)
    @test isopen(rebound)
    close(rebound)
end
