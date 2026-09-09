using Test

const STEP1_ARTIFACT_DIR = mktempdir()
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(STEP1_ARTIFACT_DIR, "conductor_events.csv")

include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))

function reset_node_runtime_state!()
    lock(node_states_lock) do
        empty!(node_states)
    end
    return nothing
end

try
    @testset "Conductor Node Runtime State" begin
        reset_node_runtime_state!()
        node = NODES("127.0.0.1", 18001, "controlled-node")

        initial = get_node_runtime_state(node)
        @test initial.state == NODE_DOWN
        @test initial.generation == UInt64(0)
        @test isempty(initial.task_id)
        @test isempty(initial.job_id)
        @test isempty(node_states)

        set_node_state!(node, NODE_IDLE)
        idle = get_node_runtime_state(node)
        @test idle.state == NODE_IDLE
        @test idle.generation == UInt64(1)
        @test isempty(idle.task_id)
        @test isempty(idle.job_id)
        @test get_node_state(node) == NODE_IDLE

        @test try_reserve_node!(node, "task-a")
        reserved = get_node_runtime_state(node)
        @test reserved.state == NODE_RESERVED
        @test reserved.generation == UInt64(2)
        @test reserved.task_id == "task-a"
        @test isempty(reserved.job_id)

        @test !try_reserve_node!(node, "task-b")
        @test get_node_runtime_state(node) == reserved
        @test_throws ArgumentError try_reserve_node!(node, "")

        @test !apply_observed_node_state!(node, NODE_IDLE, reserved.generation)
        @test get_node_runtime_state(node) == reserved
        @test_throws ArgumentError apply_observed_node_state!(
            node,
            NODE_RESERVED,
            reserved.generation
        )

        @test !mark_node_running!(node, "task-b", "job-a")
        @test get_node_runtime_state(node) == reserved
        @test mark_node_running!(node, "task-a", "job-a")
        running = get_node_runtime_state(node)
        @test running.state == NODE_BUSY
        @test running.generation == UInt64(3)
        @test running.task_id == "task-a"
        @test running.job_id == "job-a"
        @test_throws ArgumentError mark_node_running!(node, "task-a", "")

        @test reserved.state == NODE_RESERVED
        @test reserved.generation == UInt64(2)
        @test isempty(reserved.job_id)

        @test !release_node_assignment!(node, "task-b", "job-a")
        @test !release_node_assignment!(node, "task-a", "job-b")
        @test get_node_runtime_state(node) == running
        @test_throws ArgumentError release_node_assignment!(
            node,
            "task-a",
            "job-a";
            next_state=NODE_BUSY
        )

        @test release_node_assignment!(node, "task-a", "job-a")
        released = get_node_runtime_state(node)
        @test released.state == NODE_IDLE
        @test released.generation == UInt64(4)
        @test isempty(released.task_id)
        @test isempty(released.job_id)
        @test !release_node_assignment!(node, "task-a", "job-a")

        @test !apply_observed_node_state!(node, NODE_BUSY, idle.generation)
        @test get_node_runtime_state(node) == released
        @test apply_observed_node_state!(node, NODE_BUSY, released.generation)
        observed_busy = get_node_runtime_state(node)
        @test observed_busy.state == NODE_BUSY
        @test observed_busy.generation == UInt64(5)
        @test isempty(observed_busy.task_id)
        @test isempty(observed_busy.job_id)

        set_node_state!(node, NODE_IDLE)
        legacy_idle = get_node_runtime_state(node)
        @test legacy_idle.state == NODE_IDLE
        @test legacy_idle.generation == UInt64(6)
        @test isempty(legacy_idle.task_id)
        @test isempty(legacy_idle.job_id)
        @test_throws ArgumentError set_node_state!(node, NODE_RESERVED)
        @test get_node_runtime_state(node) == legacy_idle

        println("STEP1_RESULT=PASS_NODE_RUNTIME_STATE")
    end
finally
    stop_conductor_log_writer!()
    reset_node_runtime_state!()
    rm(STEP1_ARTIFACT_DIR; recursive=true, force=true)
end
