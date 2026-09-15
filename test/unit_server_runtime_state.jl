using Test
include(joinpath(@__DIR__, "..", "syncopadeServerRuntime.jl"))

function ready_runtime()
    runtime = ServerRuntime()
    initial = runtime_snapshot(runtime)
    @test runtime_mark_ready!(runtime, initial.listener_id, initial.server_id)
    return runtime, initial.listener_id, initial.server_id
end

@testset "Runtime IDs and admission transitions" begin
    runtime = ServerRuntime()
    initial = runtime_snapshot(runtime)
    @test UUID(initial.listener_id) != UUID(initial.server_id)
    @test initial.state == :starting
    @test runtime_public_state(runtime) == :busy
    @test runtime_reserve_job!(runtime, "job") === nothing
    @test runtime_reserve_restart!(runtime, initial.listener_id, initial.server_id) == :busy
    @test !runtime_mark_ready!(runtime, "stale", initial.server_id)
    @test runtime_mark_ready!(runtime, initial.listener_id, initial.server_id)
    @test runtime_public_state(runtime) == :idle
    @test !runtime_mark_ready!(runtime, initial.listener_id, initial.server_id)
    @test_throws ArgumentError runtime_reserve_job!(runtime, "")
    @test runtime_reserve_job!(runtime, "job").state == :busy
    @test runtime_public_state(runtime) == :busy
    @test runtime_reserve_job!(runtime, "second") === nothing
    @test runtime_reserve_restart!(runtime, initial.listener_id, initial.server_id) == :busy
    @test !runtime_finish_job!(runtime, initial.listener_id, initial.server_id, "other")
    @test !runtime_finish_job!(runtime, "stale", initial.server_id, "job")
    @test !runtime_finish_job!(runtime, initial.listener_id, "stale", "job")
    @test runtime_snapshot(runtime).job_id == "job"
    @test runtime_finish_job!(runtime, initial.listener_id, initial.server_id, "job")
    @test !runtime_finish_job!(runtime, initial.listener_id, initial.server_id, "job")
    @test runtime_reserve_restart!(runtime, initial.listener_id, "stale") == :id_mismatch
    @test runtime_reserve_restart!(runtime, initial.listener_id, initial.server_id) == :accepted
    @test runtime_reserve_restart!(runtime, initial.listener_id, initial.server_id) == :busy
    @test runtime_reserve_job!(runtime, "third") === nothing
    @test runtime_replace_server_id!(runtime, "stale", initial.server_id) === nothing
    replacement = runtime_replace_server_id!(runtime, initial.listener_id, initial.server_id)
    @test replacement.listener_id == initial.listener_id
    @test replacement.server_id != initial.server_id
    @test runtime_reserve_restart!(runtime, initial.listener_id, initial.server_id) == :id_mismatch
    @test !runtime_mark_ready!(runtime, initial.listener_id, initial.server_id)
    @test !runtime_mark_unavailable!(runtime, initial.listener_id, initial.server_id)
    @test runtime_mark_ready!(runtime, replacement.listener_id, replacement.server_id)
    @test runtime_public_state(runtime) == :idle
end

@testset "Failure retains job until notification completes" begin
    runtime, listener_id, server_id = ready_runtime()
    runtime_reserve_job!(runtime, "job")
    @test runtime_mark_unavailable!(runtime, listener_id, server_id)
    @test runtime_snapshot(runtime).job_id == "job"
    @test runtime_public_state(runtime) == :down
    @test runtime_reserve_restart!(runtime, listener_id, server_id) == :busy
    @test runtime_finish_job!(runtime, listener_id, server_id, "job")
    @test runtime_snapshot(runtime).state == :unavailable
    @test runtime_reserve_job!(runtime, "next") === nothing
    @test runtime_reserve_restart!(runtime, listener_id, server_id) == :accepted
    replacement = runtime_replace_server_id!(runtime, listener_id, server_id)
    @test runtime_mark_ready!(runtime, listener_id, replacement.server_id)
end

@testset "Task and restart cannot both reserve" begin
    @test Threads.nthreads() >= 4
    for _ in 1:32
        runtime, listener_id, server_id = ready_runtime()
        task = Threads.@spawn runtime_reserve_job!(runtime, "job")
        restart = Threads.@spawn runtime_reserve_restart!(runtime, listener_id, server_id)
        got_task = fetch(task) !== nothing
        got_restart = fetch(restart) == :accepted
        @test xor(got_task, got_restart)
        @test runtime_snapshot(runtime).state == (got_task ? :busy : :restarting)
    end
    for busy in (false, true)
        runtime, listener_id, server_id = ready_runtime()
        busy && runtime_reserve_job!(runtime, "job")
        stopped = runtime_request_stop!(runtime)
        @test stopped.stop_requested
        @test runtime_reserve_restart!(runtime, listener_id, server_id) == :busy
        @test runtime_reserve_job!(runtime, "next") === nothing
        @test !runtime_mark_ready!(runtime, listener_id, server_id)
        if busy
            @test stopped.state == :busy
            @test runtime_finish_job!(runtime, listener_id, server_id, "job")
        end
        @test runtime_snapshot(runtime).state == :stopping
    end
end
