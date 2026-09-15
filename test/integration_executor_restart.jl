include(joinpath(@__DIR__, "listener_test_support.jl"))

function restart_wire(handle, snapshot)
    valid, payload = checksum(listener_request(handle, "RESTART|1|$(snapshot.listener_id)|$(snapshot.server_id)"; timeout=15))
    @test valid
    return String.(split(payload, '|'))
end

@testset "Restart preserves listener and rejects duplicate IDs" begin
    with_test_listener() do handle, dir, audit
        before = listener_runtime_info(handle)
        old = handle.supervisor.child
        socket = handle.socket
        port = handle.port
        @test checksum(listener_request(handle, "RUNTIME"))[1]
        @test split(checksum(listener_request(handle, "RESTART|1||"))[2], '|') == ["ERROR", "INVALID_RESTART_REQUEST"]
        responses = fetch.([@async restart_wire(handle, before) for _ in 1:4])
        @test count(result -> result[3] == "success", responses) == 1
        @test all(result -> result[3] in ("success", "busy", "id_mismatch"), responses)
        after = listener_runtime_info(handle)
        @test after.listener_id == before.listener_id
        @test after.listener_pid == before.listener_pid
        @test after.server_id != before.server_id
        @test after.server_pid != before.server_pid
        @test after.ready
        @test handle.socket === socket
        @test handle.port == port
        @test process_exited(old.process)
        @test restart_wire(handle, before)[3] == "id_mismatch"
        @test listener_runtime_info(handle).server_id == after.server_id
        # Lose a successful reply and retry only with the same expected IDs.
        request_socket = connect(handle.bind_ip, handle.port)
        payload = "RESTART|1|$(after.listener_id)|$(after.server_id)"
        println(request_socket, payload * "|" * checksum_hex(payload))
        close(request_socket)
        @test timedwait(() -> begin
            now = listener_runtime_info(handle)
            now.ready && now.server_id != after.server_id
        end, 15; pollint=0.01) == :ok
        recovered = listener_runtime_info(handle)
        @test restart_wire(handle, after)[3] == "id_mismatch"
        @test listener_runtime_info(handle).server_id == recovered.server_id
        # Recover a dead executor only by an explicit new request.
        kill(handle.supervisor.child.process, Base.SIGKILL)
        wait_listener_state(handle, :unavailable)
        @test restart_wire(handle, recovered)[3] == "success"
        @test listener_runtime_info(handle).ready
        println("RESTART_SINGLE listener=$(before.listener_id) parent_pid=$(before.listener_pid) old_server=$(before.server_id) old_pid=$(before.server_pid) new_server=$(after.server_id) new_pid=$(after.server_pid) port=$port")
    end
end

@testset "Restart excludes task and preserves status endpoint" begin
    with_test_listener() do handle, dir, audit
        runtime = handle.supervisor.runtime
        snapshot = runtime_snapshot(runtime)
        reservation = runtime_reserve_job!(runtime, string(uuid4()))
        @test restart_wire(handle, snapshot)[3] == "busy"
        @test runtime_snapshot(runtime).job_id == reservation.job_id
        @test runtime_finish_job!(runtime, snapshot.listener_id, snapshot.server_id, reservation.job_id)
    end
    mktempdir() do gates
        entered, release = joinpath(gates, "entered"), joinpath(gates, "release")
        with_test_listener(
            script=joinpath(@__DIR__, "fixtures", "executor_lifecycle_probe.jl"),
            extra_env=Dict("SYNCOPADE_LIFECYCLE_FIXTURE" => "delayed_stop", "SYNCOPADE_STOP_ENTERED" => entered, "SYNCOPADE_STOP_RELEASE" => release)) do handle, dir, audit
            snapshot = runtime_snapshot(handle.supervisor.runtime)
            restart = @async restart_wire(handle, snapshot)
            callback = listen(ip"127.0.0.1", 0)
            try
                @test timedwait(() -> isfile(entered), 10; pollint=0.01) == :ok
                @test listener_request(handle, "STATUS") == "STATUS|busy"
                @test split(checksum(listener_request(handle, "RUNTIME"))[2], '|')[5] == "restarting"
                @test listener_request(handle, listener_task_payload(callback, "package_marker")) == "ERROR|BUSY"
                @test restart_wire(handle, snapshot)[3] == "busy"
            finally
                write(release, "release")
                close(callback)
            end
            @test fetch(restart)[3] == "success"
            @test listener_request(handle, "STATUS") == "STATUS|idle"
        end
    end
end

@testset "Restart failure is never ready success" begin
    with_test_listener() do handle, dir, audit
        original_config = handle.supervisor.config
        before = runtime_snapshot(handle.supervisor.runtime)
        handle.supervisor.config = ExecutorLaunchConfig(startup_timeout=0.2,
            script=joinpath(dir, "missing-entrypoint.jl"))
        # Capture intentional failed-start stderr separately from the normal-child log.
        failed_errors = open(joinpath(dir, "failed-start.stderr"), "w+")
        normal_errors = handle.supervisor.errors
        handle.supervisor.errors = failed_errors
        try
            @test restart_wire(handle, before)[3] == "startup_failed"
            failed = listener_runtime_info(handle)
            @test failed.state == :unavailable
            @test !failed.ready
            @test failed.server_id != before.server_id
            @test handle.supervisor.child === nothing
            @test handle.supervisor.pending_process === nothing
            handle.supervisor.config = original_config
            handle.supervisor.errors = normal_errors
            @test restart_wire(handle, failed)[3] == "success"
        finally
            handle.supervisor.config = original_config
            handle.supervisor.errors = normal_errors
            close(failed_errors)
        end
    end
    with_test_listener(script=joinpath(@__DIR__, "fixtures", "executor_lifecycle_probe.jl"),
        shutdown_timeout=0.2, extra_env=Dict("SYNCOPADE_LIFECYCLE_FIXTURE" => "ignore_stop"),
        stderr_check=(text, child) -> begin
            child.process.termsignal in (0, Base.SIGTERM, Base.SIGKILL) || return false
            signal_dump = Regex("\\[$(child.pid)\\] signal 15:.*?Allocations: [^\\n]*(?:\\n|\\z)", "s")
            normal_listener_stderr(replace(text, signal_dump => ""))
        end) do handle, dir, audit
        before = listener_runtime_info(handle)
        child = handle.supervisor.child
        @test restart_wire(handle, before)[3] == "stop_failed"
        @test listener_runtime_info(handle).server_id == before.server_id
        @test listener_runtime_info(handle).state == :unavailable
        @test process_exited(child.process)
        @test handle.supervisor.child === nothing
    end
end
