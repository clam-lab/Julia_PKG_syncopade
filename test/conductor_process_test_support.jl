module LocalConductorTestSupport
using Test, Sockets
include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))
export start_local_conductor, stop_local_conductor, local_conductor_request

function start_local_conductor(nodes, dir; monitor=false, extra_env=Dict{String,String}())
    reserved = listen(ip"127.0.0.1", 0)
    port = Int(getsockname(reserved)[2])
    close(reserved)
    output = open(joinpath(dir, "conductor.stdout"), "w+")
    errors = open(joinpath(dir, "conductor.stderr"), "w+")
    log_path = joinpath(dir, "conductor.csv")
    node_list = join(["$(node.ip),$(node.port),$(node.name)" for node in nodes], ';')
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) --threads=4 $(joinpath(@__DIR__, "fixtures", "local_conductor_process.jl")) $port`
    env = merge(Dict("SYNCOPADE_TEST_NODES" => node_list, "SYNCOPADE_TEST_MONITOR" => string(monitor), "SYNCOPADE_CONDUCTOR_LOG" => log_path), extra_env)
    process = open(pipeline(addenv(command, env); stderr=errors), "w", output)
    child = (; process, port, output, errors, log_path, dir)
    ready = timedwait(10; pollint=0.05) do
        process_exited(process) && return true
        try
            management_request("127.0.0.1", port, "LIST"; timeout=0.3)
            return true
        catch
            return false
        end
    end
    if ready != :ok || process_exited(process)
        try
            stop_local_conductor(child)
        finally
            error("local conductor did not start: $(read(joinpath(dir, "conductor.stderr"), String))")
        end
    end
    return child
end

local_conductor_request(child, payload; timeout=5.0) = management_request("127.0.0.1", child.port, payload; timeout)

function stop_local_conductor(child)
    if process_running(child.process)
        write(child.process, "q\n")
        flush(child.process)
        close(child.process.in)
        if timedwait(() -> process_exited(child.process), 10; pollint=0.01) != :ok
            kill(child.process, Base.SIGKILL)
            wait(child.process)
            error("local conductor did not stop normally")
        end
    end
    wait(child.process)
    @test child.process.exitcode == 0
    close(child.output)
    close(child.errors)
    @test isempty(read(joinpath(child.dir, "conductor.stderr"), String))
    rebound = listen(ip"127.0.0.1", child.port)
    @test isopen(rebound)
    close(rebound)
end
end
