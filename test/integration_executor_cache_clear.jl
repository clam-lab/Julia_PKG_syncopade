include(joinpath(@__DIR__, "listener_test_support.jl"))
module CacheConductor
include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))
end

@testset "Cache reservation excludes restart until settled" begin
    runtime = ServerRuntime()
    first = runtime_snapshot(runtime)
    @test runtime_mark_ready!(runtime, first.listener_id, first.server_id)
    clear = runtime_reserve_cache_clear!(runtime)
    @test clear !== nothing
    @test isempty(clear.job_id)
    @test !isempty(clear.control_id)
    @test runtime_reserve_job!(runtime, string(uuid4())) === nothing
    @test runtime_reserve_restart!(runtime, first.listener_id, first.server_id) == :busy
    @test runtime_mark_unavailable!(runtime, first.listener_id, first.server_id)
    @test runtime_reserve_restart!(runtime, first.listener_id, first.server_id) == :busy
    @test runtime_finish_cache_clear!(runtime, clear)
    @test !runtime_finish_cache_clear!(runtime, clear)
    @test runtime_reserve_restart!(runtime, first.listener_id, first.server_id) == :accepted
end

@testset "Cache relay preserves process and loaded package" begin
    mktempdir() do assets
        package_root = joinpath(assets, "packages")
        cp(joinpath(@__DIR__, "fixtures", "package_reload", "v1"), package_root)
        separator = Sys.iswindows() ? ';' : ':'
        with_test_listener(extra_env=Dict("JULIA_LOAD_PATH" => join([package_root, "@", "@stdlib"], separator))) do handle, dir, audit
            before = runtime_snapshot(handle.supervisor.runtime)
            child_pid = handle.supervisor.child.pid
            fixture = joinpath(dir, "wrapper.jl")
            code = "module ListenerProbe\nusing ReloadProbe\npackage_marker() = \"taskV1,\" * ReloadProbe.marker() * \",\" * string(getpid())\nend\n"
            write(fixture, code)
            callback = listen(ip"127.0.0.1", 0)
            function marker()
                response = listener_request(handle, listener_task_payload(callback, "package_marker"; fixture))
                @test startswith(response, "OK|STARTED|")
                fields = receive_listener_callback(callback)
                wait_listener_state(handle, :idle)
                return fields[4]
            end
            try
                @test marker() == "taskV1,V1,$child_pid"
                write(fixture, replace(code, "taskV1" => "taskV2"))
                cp(joinpath(@__DIR__, "fixtures", "package_reload", "v2", "ReloadProbe", "src", "ReloadProbe.jl"),
                    joinpath(package_root, "ReloadProbe", "src", "ReloadProbe.jl"); force=true)
                @test marker() == "taskV1,V1,$child_pid"
                @test listener_request(handle, "CACHE_CLEAR") == "CACHE|CLEARED|1"
                @test marker() == "taskV2,V1,$child_pid"
                after = runtime_snapshot(handle.supervisor.runtime)
                @test (before.listener_id, before.server_id) == (after.listener_id, after.server_id)
                @test handle.supervisor.child.pid == child_pid
                @test isempty(after.control_id)
                withenv("SYNCOPADE_CONDUCTOR_LOG" => joinpath(dir, "conductor.csv")) do
                    try
                        node = CacheConductor.NODES("127.0.0.1", handle.port, "local")
                        result = CacheConductor.clear_all_node_caches([node])
                        @test result == (total_nodes=1, success_nodes=1, failed_nodes=0, cleared_functions=1)
                    finally
                        CacheConductor.stop_conductor_log_writer!()
                    end
                end
            finally
                close(callback)
            end
        end
    end
end

@testset "Busy and unavailable cache clear are failures" begin
    with_test_listener() do handle, dir, audit
        callback = listen(ip"127.0.0.1", 0)
        ready, release = joinpath(dir, "ready"), joinpath(dir, "release")
        try
            listener_request(handle, listener_task_payload(callback, "pause", [ready, release]))
            @test timedwait(() -> isfile(ready), 10; pollint=0.01) == :ok
            before = runtime_snapshot(handle.supervisor.runtime)
            @test listener_request(handle, "CACHE_CLEAR") == "ERROR|BUSY"
            @test runtime_snapshot(handle.supervisor.runtime) == before
            withenv("SYNCOPADE_CONDUCTOR_LOG" => joinpath(dir, "conductor.csv")) do
                try
                    result = CacheConductor.clear_all_node_caches([CacheConductor.NODES("127.0.0.1", handle.port, "busy")])
                    @test result == (total_nodes=1, success_nodes=0, failed_nodes=1, cleared_functions=0)
                finally
                    CacheConductor.stop_conductor_log_writer!()
                end
            end
            write(release, "release")
            @test receive_listener_callback(callback)[3] == "OK"
            wait_listener_state(handle, :idle)
            kill(handle.supervisor.child.process, Base.SIGKILL)
            wait_listener_state(handle, :unavailable)
            @test listener_request(handle, "CACHE_CLEAR") == "ERROR|CACHE_CLEAR_UNAVAILABLE"
        finally
            write(release, "release")
            close(callback)
        end
    end
    withenv("SYNCOPADE_EXECUTOR_CACHE_TIMEOUT" => "0.2") do
        with_test_listener(extra_env=Dict("SYNCOPADE_LIFECYCLE_FIXTURE" => "ignore_clear"),
            script=joinpath(@__DIR__, "fixtures", "executor_lifecycle_probe.jl")) do handle, dir, audit
            before = runtime_snapshot(handle.supervisor.runtime)
            @test listener_request(handle, "CACHE_CLEAR") == "ERROR|CACHE_CLEAR_FAILED"
            @test runtime_snapshot(handle.supervisor.runtime).state == :unavailable
            @test runtime_snapshot(handle.supervisor.runtime).server_id == before.server_id
            @test isempty(runtime_snapshot(handle.supervisor.runtime).control_id)
            @test wait_executor_exit(handle.supervisor.child.process, 5)
        end
    end
end
