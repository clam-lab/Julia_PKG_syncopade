using Test, Sockets, UUIDs
include(joinpath(@__DIR__, "..", "syncopadeExecutorProtocol.jl"))
using .ExecutorProtocol

function executor_loop_case(disconnect::Bool)
    mktempdir() do dir
        listener = listen(ip"127.0.0.1", 0)
        port = getsockname(listener)[2]
        listener_id, server_id = string(uuid4()), string(uuid4())
        output_path, error_path = joinpath(dir, "stdout"), joinpath(dir, "stderr")
        command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__, "..", "scripts", "run_executor.jl")) $port $listener_id $server_id`
        process = run(pipeline(command; stdout=output_path, stderr=error_path); wait=false)
        socket = nothing
        watchdog = Timer(20) do _
            close(listener)
            socket === nothing || close(socket)
            process_running(process) && kill(process)
        end
        try
            socket = accept(listener)
            ready = expect_executor_message(read_executor_message(socket), "READY", listener_id, server_id, "")
            child_pid = parse(Int, ready.data[1])
            @test child_pid != getpid()
            @test child_pid == getpid(process)
            @test ready.data[2] == string(VERSION)
            @test ready.data[3] == "0.1.4"
            if disconnect
                close(socket)
            else
                fixture = joinpath(@__DIR__, "fixtures", "executor_probe.jl")
                for (func, args, expected) in [
                    ("echo", ["", "a|b\n先生"], ["OK", "|a|b\n先生"]),
                    ("pid", String[], ["OK", string(child_pid)]),
                    ("fail", String[], ["ERROR", "ARG_ERROR", "ArgumentError: deliberate fixture failure"]),
                    ("echo", ["after-error"], ["OK", "after-error"]),
                    ("noisy", String[], ["OK", "noise-complete"]),
                    ("pid", String[], ["OK", string(child_pid)]),
                ]
                    job_id = string(uuid4())
                    write_executor_message(socket, ExecutorMessage("EXECUTE", listener_id, server_id, job_id,
                        vcat([fixture, "ExecutorProbe", func], args)))
                    result = expect_executor_message(read_executor_message(socket), "RESULT", listener_id, server_id, job_id)
                    @test result.data == expected
                    @test process_running(process)
                end
                clear_id = string(uuid4())
                write_executor_message(socket, ExecutorMessage("CLEAR", listener_id, server_id, clear_id, String[]))
                cleared = expect_executor_message(read_executor_message(socket), "CLEARED", listener_id, server_id, clear_id)
                @test cleared.data == ["4"]
                stop_id = string(uuid4())
                write_executor_message(socket, ExecutorMessage("STOP", listener_id, server_id, stop_id, String[]))
                @test expect_executor_message(read_executor_message(socket), "STOPPED", listener_id, server_id, stop_id).data == String[]
            end
            wait(process)
            @test process.exitcode == 0
            @test !process_running(process)
            if !disconnect
                @test read(output_path, String) == "x"^(256 * 1024)
            end
            # Module replacement warnings depend on Julia's warning settings.
            warnings = split(read(error_path, String), '\n'; keepempty=false)
            @test all(==("WARNING: replacing module ExecutorProbe."), warnings)
            @test disconnect ? isempty(warnings) : length(warnings) in (0, 3)
            println("EXECUTOR_LOOP disconnect=$disconnect listener=$listener_id server=$server_id child_pid=$child_pid exit=$(process.exitcode)")
        finally
            close(watchdog)
            socket === nothing || close(socket)
            close(listener)
            if process_running(process)
                kill(process)
                wait(process)
            end
        end
        rebound = listen(ip"127.0.0.1", port)
        @test isopen(rebound)
        close(rebound)
    end
end

@testset "Executor loop and cleanup" begin
    executor_loop_case(false)
    executor_loop_case(true)
end
