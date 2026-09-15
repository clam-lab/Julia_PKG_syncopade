include(joinpath(@__DIR__, "listener_test_support.jl"))

@testset "Executor death is not task retry" begin
    with_test_listener() do handle, dir, audit
        child = handle.supervisor.child
        callback = listen(ip"127.0.0.1", 0)
        try
            # Fix the admission-to-execution boundary without a timing race.
            job = convMSG2JOB(listener_task_payload(callback, "package_marker"))
            reservation = runtime_reserve_job!(handle.supervisor.runtime, string(uuid4()))
            @test reservation !== nothing
            kill(child.process, Base.SIGKILL)
            wait_listener_state(handle, :unavailable)
            handle.job_task = @async execute_listener_job!(handle, job, reservation)
            result = receive_listener_callback(callback)
            @test result[1:4] == ["RESULT", reservation.job_id, "ERROR", "EXECUTOR_UNAVAILABLE"]
            wait(handle.job_task)
            @test runtime_snapshot(handle.supervisor.runtime).job_id == ""
            @test runtime_snapshot(handle.supervisor.runtime).state == :unavailable
        finally
            close(callback)
        end
    end
    with_test_listener() do handle, dir, audit
        child = handle.supervisor.child
        kill(child.process, Base.SIGKILL)
        wait_listener_state(handle, :unavailable)
        @test listener_request(handle, "STATUS") == "STATUS|down"
        @test handle.supervisor.child === child
        @test runtime_snapshot(handle.supervisor.runtime).job_id == ""
        callback = listen(ip"127.0.0.1", 0)
        try
            @test listener_request(handle, listener_task_payload(callback, "package_marker")) == "ERROR|BUSY"
        finally
            close(callback)
        end
    end
    with_test_listener() do handle, dir, audit
        child = handle.supervisor.child
        callback = listen(ip"127.0.0.1", 0)
        conductor = listen(ip"127.0.0.1", 0)
        task_id = string(uuid4())
        ready, release = joinpath(dir, "ready"), joinpath(dir, "release")
        try
            response = listener_request(handle, listener_task_payload(callback, "pause", [ready, release]; conductor, task_id))
            job_id = String(split(response, '|')[3])
            @test timedwait(() -> isfile(ready), 10; pollint=0.01) == :ok
            kill(child.process, Base.SIGKILL)
            result = receive_listener_callback(callback)
            @test result[1:5] == ["TASK_RESULT", task_id, job_id, "ERROR", "EXECUTOR_UNAVAILABLE"]
            @test occursin("side effects may have occurred", result[6])
            done = receive_listener_callback(conductor; ack=true)
            @test done[1:3] == ["DONE", task_id, job_id]
            @test done[6] == "ERROR"
            wait(handle.job_task)
            @test runtime_snapshot(handle.supervisor.runtime).state == :unavailable
            @test runtime_snapshot(handle.supervisor.runtime).job_id == ""
            @test handle.supervisor.child === child
            records = String(take!(audit))
            @test count("event=job_reserved", records) == 1
            @test count("event=job_finished", records) == 1
            @test count("event=starting", records) == 1
            @test occursin("unexpected=true", records)
        finally
            write(release, "release")
            close(callback)
            close(conductor)
        end
    end
end

@testset "Death after result preserves result and unavailable state" begin
    with_test_listener() do handle, dir, audit
        child = handle.supervisor.child
        callback = listen(ip"127.0.0.1", 0)
        conductor = listen(ip"127.0.0.1", 0)
        done_socket = nothing
        try
            task_id = string(uuid4())
            response = listener_request(handle, listener_task_payload(callback, "package_marker"; conductor, task_id))
            job_id = String(split(response, '|')[3])
            @test receive_listener_callback(callback) == ["TASK_RESULT", task_id, job_id, "OK", "V1,$(child.pid)"]
            done_socket = accept(conductor)
            valid, done = checksum(readline(done_socket))
            @test valid
            @test split(done, '|')[6] == "OK"
            kill(child.process, Base.SIGKILL)
            wait_listener_state(handle, :unavailable)
            snapshot = runtime_snapshot(handle.supervisor.runtime)
            @test snapshot.job_id == job_id
            @test runtime_reserve_restart!(handle.supervisor.runtime, snapshot.listener_id, snapshot.server_id) == :busy
            println(done_socket, "OK|" * checksum_hex("OK"))
            close(done_socket)
            wait(handle.job_task)
            @test runtime_snapshot(handle.supervisor.runtime).state == :unavailable
            @test runtime_snapshot(handle.supervisor.runtime).job_id == ""
        finally
            done_socket === nothing || close(done_socket)
            close(callback)
            close(conductor)
        end
    end
end

@testset "Late result cannot finish another job" begin
    with_test_listener() do handle, dir, audit
        callback = listen(ip"127.0.0.1", 0)
        ready, release = joinpath(dir, "ready"), joinpath(dir, "release")
        runtime = handle.supervisor.runtime
        try
            listener_request(handle, listener_task_payload(callback, "pause", [ready, release]))
            @test timedwait(() -> isfile(ready), 10; pollint=0.01) == :ok
            old = runtime_snapshot(runtime)
            @test runtime_finish_job!(runtime, old.listener_id, old.server_id, old.job_id)
            next = runtime_reserve_job!(runtime, string(uuid4()))
            @test next !== nothing
            write(release, "release")
            wait(handle.job_task)
            @test runtime_snapshot(runtime) == next
            records = String(take!(audit))
            @test count("event=stale_job_ignored", records) == 1
            @test count("event=job_finished", records) == 0
            @test runtime_finish_job!(runtime, next.listener_id, next.server_id, next.job_id)
        finally
            write(release, "release")
            close(callback)
        end
    end
end
