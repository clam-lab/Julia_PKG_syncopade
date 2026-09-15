include(joinpath(@__DIR__, "conductor_listener_test_support.jl"))

@testset "Conductor holds BUSY through single executor replacement" begin
    mktempdir() do gates
        refresh_entered, refresh_release = joinpath(gates, "observed"), joinpath(gates, "dispatch")
        stop_entered, stop_release = joinpath(gates, "stopping"), joinpath(gates, "replace")
        monitor_gate = joinpath(gates, "monitor")
        with_test_listener(script=joinpath(@__DIR__, "fixtures", "gated_executor.jl"), shutdown_timeout=20.0,
            extra_env=Dict("SYNCOPADE_STOP_ENTERED" => stop_entered, "SYNCOPADE_STOP_RELEASE" => stop_release)) do handle, dir, audit
            @test listener_request(handle, "STATUS") == "STATUS|idle"
            conductor = start_local_conductor([(ip="127.0.0.1", port=handle.port, name="one")], dir; monitor=true,
                extra_env=Dict("SYNCOPADE_TEST_REFRESH_ENTERED" => refresh_entered, "SYNCOPADE_TEST_REFRESH_RELEASE" => refresh_release,
                    "SYNCOPADE_TEST_MONITOR_GATE" => monitor_gate))
            callback = listen(ip"127.0.0.1", 0)
            trace = joinpath(dir, "executions.csv")
            try
                first = submit_local_probe(conductor, callback, "counted", [trace, "1"])
                @test timedwait(() -> isfile(refresh_entered), 10; pollint=0.01) == :ok
                before = listener_runtime_info(handle)
                restart = @async Syncopade.restart_server_executor("127.0.0.1"; server_port=handle.port,
                    expected_listener_id=before.listener_id, expected_server_id=before.server_id)
                @test timedwait(() -> isfile(stop_entered), 10; pollint=0.01) == :ok
                write(refresh_release, "dispatch")
                @test timedwait(() -> isfile(conductor.log_path) && occursin("\"DISPATCH_BUSY\",\"$first\",\"0\",", read(conductor.log_path, String)), 10; pollint=0.02) == :ok
                status = Syncopade.query_conductor_task_status("127.0.0.1", first; conductor_port=conductor.port)
                @test status.state == :queued
                @test !isfile(trace)
                tasks = Dict(first => "1")
                for label in ("2", "3", "4")
                    tasks[submit_local_probe(conductor, callback, "counted", [trace, label])] = label
                end
                write(stop_release, "replace")
                result = fetch(restart)
                @test result.status == :success
                @test result.runtime.listener_id == before.listener_id
                write(monitor_gate, "monitor")
                verify_probe_batch(conductor, callback, tasks, [result.runtime.server_pid], trace)
                records = String(take!(audit))
                @test count("event=job_reserved", records) == 4
                @test count("event=job_finished", records) == 4
            finally
                write(refresh_release, "dispatch")
                write(stop_release, "replace")
                write(monitor_gate, "monitor")
                stop_local_conductor(conductor)
                close(callback)
            end
        end
    end
end

@testset "Accepted executor crash reaches conductor terminal" begin
    with_test_listener() do handle, dir, audit
        conductor = start_local_conductor([(ip="127.0.0.1", port=handle.port, name="crash")], dir; monitor=true)
        callback = listen(ip"127.0.0.1", 0)
        ready, release = joinpath(dir, "ready"), joinpath(dir, "release")
        try
            task_id = submit_local_probe(conductor, callback, "pause", [ready, release])
            @test timedwait(() -> isfile(ready), 10; pollint=0.01) == :ok
            kill(handle.supervisor.child.process, Base.SIGKILL)
            result = receive_listener_callback(callback)
            @test result[1:2] == ["TASK_RESULT", task_id]
            @test result[4:5] == ["ERROR", "EXECUTOR_UNAVAILABLE"]
            status = terminal_status(conductor, task_id)
            @test status.job_id == result[3]
            @test status.terminal_kind == "WORKER_DONE_ERROR"
            @test occursin("EXECUTOR_UNAVAILABLE", status.reason)
            wait(handle.job_task)
            @test runtime_snapshot(handle.supervisor.runtime).state == :unavailable
            @test count("event=job_reserved", String(take!(audit))) == 1
        finally
            write(release, "release")
            stop_local_conductor(conductor)
            close(callback)
        end
    end
end
