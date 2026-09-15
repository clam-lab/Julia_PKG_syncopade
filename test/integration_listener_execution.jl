include(joinpath(@__DIR__, "listener_test_support.jl"))

@testset "Public listener executes only in child" begin
    with_test_listener() do handle, dir, audit
        snapshot = runtime_snapshot(handle.supervisor.runtime)
        child_pid = handle.supervisor.child.pid
        @test child_pid != getpid()
        @test !isdefined(Main, :ListenerProbe)
        @test !any(id -> id.name == "ReloadProbe", keys(Base.loaded_modules))
        @test listener_request(handle, "STATUS") == "STATUS|idle"
        @test listener_request(handle, "CACHE_CLEAR") == "CACHE|CLEARED|0"
        callback = listen(ip"127.0.0.1", 0)
        conductor = listen(ip"127.0.0.1", 0)
        try
            response = listener_request(handle, listener_task_payload(callback, "package_marker"))
            fields = split(response, '|')
            @test fields[1:2] == ["OK", "STARTED"]
            result = receive_listener_callback(callback)
            @test result == ["RESULT", fields[3], "OK", "V1,$child_pid"]
            wait_listener_state(handle, :idle)
            @test !isdefined(Main, :ListenerProbe)
            @test !any(id -> id.name == "ReloadProbe", keys(Base.loaded_modules))
            @test handle.supervisor.child.pid == child_pid
            task_id = string(uuid4())
            response = listener_request(handle, listener_task_payload(callback, "fail"; conductor, task_id))
            job_id = String(split(response, '|')[3])
            result = receive_listener_callback(callback)
            @test result == ["TASK_RESULT", task_id, job_id, "ERROR", "ARG_ERROR", "ArgumentError: listener fixture failure"]
            done = receive_listener_callback(conductor; ack=true)
            @test done[1:6] == ["DONE", task_id, job_id, "127.0.0.1", string(handle.port), "ERROR"]
            @test done[9] == "true"
            wait_listener_state(handle, :idle)

            ready_file, release_file = joinpath(dir, "ready"), joinpath(dir, "release")
            response = listener_request(handle, listener_task_payload(callback, "pause", [ready_file, release_file]))
            job_id = String(split(response, '|')[3])
            @test timedwait(() -> isfile(ready_file), 10; pollint=0.01) == :ok
            @test read(ready_file, String) == string(child_pid)
            @test listener_request(handle, "STATUS") == "STATUS|busy"
            requests = [@async listener_request(handle, listener_task_payload(callback, "package_marker")) for _ in 1:4]
            @test fetch.(requests) == fill("ERROR|BUSY", 4)
            @test runtime_snapshot(handle.supervisor.runtime).job_id == job_id
            write(release_file, "release")
            @test receive_listener_callback(callback) == ["RESULT", job_id, "OK", "released,$child_pid"]
            wait_listener_state(handle, :idle)
            after = runtime_snapshot(handle.supervisor.runtime)
            @test after.listener_id == snapshot.listener_id
            @test after.server_id == snapshot.server_id
            records = String(take!(audit))
            @test count("event=job_reserved", records) == 3
            @test count("event=job_finished", records) == 3
            @test occursin("job_id=$job_id", records)
            println("LISTENER_EXECUTION parent_pid=$(getpid()) child_pid=$child_pid listener=$(after.listener_id) server=$(after.server_id) jobs=3 busy_rejections=4")
        finally
            close(callback)
            close(conductor)
            # Always release the controlled job if an assertion fails.
            write(joinpath(dir, "release"), "release")
        end
    end
end
