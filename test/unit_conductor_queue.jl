using Test

const QUEUE_TEST_ARTIFACT_DIR = mktempdir()
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(
    QUEUE_TEST_ARTIFACT_DIR,
    "conductor_events.csv"
)

include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))

try
    @testset "Conductor Queue" begin
        lock(task_queue_lock) do
            empty!(task_queue)
        end
        lock(task_runtime_states_lock) do
            empty!(task_runtime_states)
            empty!(task_acceptance_windows)
            empty!(conductor_task_records)
            empty!(task_terminal_notifications)
        end

        @test default_callback_port("192.168.1.37") == 8037

        t1 = parse_submit_task("SUBMIT|192.168.1.10|9010|testScript:testScript4syncopade:test_syncopade|a1|a2")
        @test t1.coordinator_ip == "192.168.1.10"
        @test t1.coordinator_port == 9010
        @test t1.source == "testScript"
        @test t1.module_name == "testScript4syncopade"
        @test t1.function_name == "test_syncopade"
        @test t1.args == ["a1", "a2"]
        @test t1.retry_count == 0

        t2 = parse_submit_task("SUBMIT|192.168.1.10|testScript:testScript4syncopade:test_syncopade")
        @test t2.coordinator_port == 8010

        enqueue_task!(t1)
        enqueue_task!(t2)
        p1 = pop_task!()
        p2 = pop_task!()
        p3 = pop_task!()

        @test p1 !== nothing && p1.task_id == t2.task_id
        @test p2 !== nothing && p2.task_id == t1.task_id
        @test p3 === nothing

        seed = ConductorTask("task-retry", "127.0.0.1", 1, "s", "m", "f", String[], 2)
        enqueue_task!(seed)
        @test pop_task!() === seed
        @test mark_task_reserved!(seed.task_id)
        requeue_with_retry!(seed; max_retry=3)
        r = pop_task!()
        @test r !== nothing
        @test r.retry_count == 3

        @test mark_task_reserved!(r.task_id)
        requeue_with_retry!(r; max_retry=3)
        @test queue_len() == 0

        nodes = [
            NODES("192.168.1.101", 8101, "A"),
            NODES("192.168.1.102", 8102, "B"),
            NODES("192.168.1.103", 8103, "C")
        ]

        set_node_state!(nodes[1], NODE_IDLE)
        set_node_state!(nodes[2], NODE_BUSY)
        set_node_state!(nodes[3], NODE_IDLE)

        picked = pick_idle_node_right_to_left(nodes)
        @test picked !== nothing
        @test picked.name == "C"

        lock(node_states_lock) do
            empty!(node_states)
        end
    end
finally
    stop_conductor_log_writer!()
    rm(QUEUE_TEST_ARTIFACT_DIR; recursive=true, force=true)
end
