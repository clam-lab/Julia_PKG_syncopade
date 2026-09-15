using Test
include(joinpath(@__DIR__, "..", "syncopadeServerRuntime.jl"))

function lifecycle_case(mode::String)
    mktempdir() do dir
        audit = IOBuffer()
        output = open(joinpath(dir, "stdout"), "w+")
        errors = open(joinpath(dir, "stderr"), "w+")
        config = ExecutorLaunchConfig(
            cwd=dir, threads="2,0", startup_timeout=mode == "normal" ? 10.0 : 3.0,
            shutdown_timeout=0.3, cleanup_timeout=2.0,
            env=merge(Dict(ENV), Dict("SYNCOPADE_LIFECYCLE_FIXTURE" => mode, "SYNCOPADE_ENV_PROBE" => "inherited-value")),
            script=mode == "normal" ? joinpath(@__DIR__, "..", "scripts", "run_executor.jl") : joinpath(@__DIR__, "fixtures", "executor_lifecycle_probe.jl"))
        runtime = ServerRuntime()
        before = runtime_snapshot(runtime)
        supervisor = ExecutorSupervisor(runtime; config, audit, output, errors)
        owned = nothing
        try
            @test before.state == :starting
            result = launch_executor!(supervisor)
            after = runtime_snapshot(runtime)
            @test before.listener_id == after.listener_id
            @test before.server_id == after.server_id
            @test supervisor.pending_process === nothing
            if mode in ("normal", "ignore_stop")
                @test result.ok
                @test after.state == :idle
                owned = supervisor.child
                @test owned.pid == result.pid
                @test owned.pid != getpid()
                @test process_running(owned.process)
                @test !launch_executor!(supervisor).ok
                @test stop_executor!(supervisor).reason == :busy
                if mode == "normal"
                    id = string(uuid4())
                    request = ExecutorMessage("EXECUTE", before.listener_id, before.server_id, id,
                        [joinpath(@__DIR__, "fixtures", "executor_probe.jl"), "ExecutorProbe", "environment", "SYNCOPADE_ENV_PROBE"])
                    response = executor_exchange(owned, request, "RESULT"; timeout=10)
                    @test response.data[1] == "OK"
                    fields = split(response.data[2], '|')
                    @test realpath(fields[1]) == realpath(joinpath(config.project, "Project.toml"))
                    @test realpath(fields[2]) == realpath(dir)
                    @test fields[3:end] == ["inherited-value", "2", "0"]
                end
                @test runtime_reserve_restart!(runtime, before.listener_id, before.server_id) == :accepted
                stopped = stop_executor!(supervisor)
                @test stopped.ok == (mode == "normal")
                @test process_exited(owned.process)
                @test !isopen(owned.socket)
                @test supervisor.child === nothing
                if mode == "ignore_stop"
                    @test stopped.reason == :stop_failed
                    @test runtime_snapshot(runtime).state == :unavailable
                else
                    @test owned.process.exitcode == 0
                end
            else
                @test !result.ok
                @test after.state == :unavailable
                @test supervisor.child === nothing
                @test result.reason == (mode == "no_ready" ? :startup_timeout : :startup_failed)
                @test stop_executor!(supervisor).ok
            end
            records = String(take!(audit))
            @test occursin("listener_id=$(before.listener_id)", records)
            @test occursin("server_id=$(before.server_id)", records)
            @test occursin("pid=$(result.pid)", records)
            @test occursin(mode in ("normal", "ignore_stop") ? "event=ready" : "event=startup_failed", records)
            port_match = match(r"control_port=(\d+)", records)
            @test port_match !== nothing
            rebound = listen(ip"127.0.0.1", parse(Int, port_match[1]))
            @test isopen(rebound)
            close(rebound)
            if !(mode in ("normal", "ignore_stop"))
                @test occursin("reaped=true", records)
            end
            flush(errors)
            seekstart(errors)
            stderr_text = read(errors, String)
            if mode == "normal"
                @test isempty(stderr_text)
            elseif mode == "throw_before"
                @test occursin("deliberate startup fixture error", stderr_text)
            end
            println("EXECUTOR_LIFECYCLE mode=$mode listener=$(before.listener_id) server=$(before.server_id) pid=$(result.pid) result=$(result.reason) owned_child_reaped=true")
        finally
            runtime_request_stop!(runtime)
            stop_executor!(supervisor)
            close(output)
            close(errors)
        end
    end
end

@testset "Executor launch configuration and lifecycle" begin
    @test_throws ArgumentError ExecutorLaunchConfig(startup_timeout=0)
    @test_throws ArgumentError ExecutorLaunchConfig(shutdown_timeout=Inf)
    withenv("SYNCOPADE_EXECUTOR_STARTUP_TIMEOUT" => "wrong") do
        @test_throws ArgumentError ExecutorLaunchConfig()
    end
    for mode in ("normal", "exit_before", "throw_before", "no_ready", "bad_id", "ignore_stop")
        lifecycle_case(mode)
    end
end
