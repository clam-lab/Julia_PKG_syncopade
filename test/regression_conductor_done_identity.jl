using Test

const STEP4_ARTIFACT_DIR = mktempdir()
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(STEP4_ARTIFACT_DIR, "conductor_events.csv")

include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))

function reset_done_test_state!()
    lock(task_queue_lock) do
        empty!(task_queue)
    end
    lock(node_states_lock) do
        empty!(node_states)
    end
    return nothing
end

function done_payload(
    task_id::String,
    job_id::String,
    ip::String,
    port::Int;
    status::String="OK",
    callback_ok::String="true",
    error_message::String="none"
)::String
    return join(
        String[
            "DONE",
            task_id,
            job_id,
            ip,
            string(port),
            status,
            "2026-09-09T00:00:00.000",
            "2026-09-09T00:00:01.000",
            callback_ok,
            error_message
        ],
        "|"
    )
end

function assign_running!(node::NODES, task_id::String, job_id::String)
    set_node_state!(node, NODE_IDLE)
    try_reserve_node!(node, task_id) || error("failed to reserve $task_id")
    mark_node_running!(node, task_id, job_id) || error("failed to start $task_id/$job_id")
    return get_node_runtime_state(node)
end

try
    @testset "Conductor DONE Identity" begin
        reset_done_test_state!()
        node = NODES("127.0.0.1", 18201, "done-node")

        assign_running!(node, "task-a", "job-a")
        @test handle_done_payload(done_payload("task-a", "job-a", node.IP, node.port))
        state_after_a = get_node_runtime_state(node)
        @test state_after_a.state == NODE_IDLE
        @test isempty(state_after_a.task_id)
        @test isempty(state_after_a.job_id)

        state_b = assign_running!(node, "task-b", "job-b")
        @test !handle_done_payload(done_payload("task-a", "job-a", node.IP, node.port))
        @test get_node_runtime_state(node) == state_b

        @test !handle_done_payload(done_payload("task-b", "job-wrong", node.IP, node.port))
        @test get_node_runtime_state(node) == state_b

        unknown_node = NODES("127.0.0.1", 18299, "unknown")
        @test !handle_done_payload(done_payload(
            "task-unknown",
            "job-unknown",
            unknown_node.IP,
            unknown_node.port
        ))
        @test get_node_runtime_state(node) == state_b
        @test !haskey(node_states, (unknown_node.IP, unknown_node.port))

        @test handle_done_payload(done_payload("task-b", "job-b", node.IP, node.port))
        state_after_b = get_node_runtime_state(node)
        @test state_after_b.state == NODE_IDLE
        @test isempty(state_after_b.task_id)
        @test isempty(state_after_b.job_id)

        @test !handle_done_payload(done_payload("task-b", "job-b", node.IP, node.port))
        @test get_node_runtime_state(node) == state_after_b

        @test try_reserve_node!(node, "task-c")
        reserved_c = get_node_runtime_state(node)
        @test reserved_c.state == NODE_RESERVED
        @test isempty(reserved_c.job_id)
        @test handle_done_payload(done_payload("task-c", "job-c", node.IP, node.port))
        state_after_c = get_node_runtime_state(node)
        @test state_after_c.state == NODE_IDLE
        @test isempty(state_after_c.task_id)
        @test isempty(state_after_c.job_id)
        @test !mark_node_running!(node, "task-c", "job-c")

        before_malformed = get_node_runtime_state(node)
        @test_throws ArgumentError handle_done_payload("DONE|too|short")
        @test get_node_runtime_state(node) == before_malformed

        stop_conductor_log_writer!()
        log_lines = readlines(ENV["SYNCOPADE_CONDUCTOR_LOG"])
        task_done_lines = filter(line -> occursin("\"TASK_DONE\"", line), log_lines)
        ignored_lines = filter(line -> occursin("\"DONE_IGNORED\"", line), log_lines)
        @test length(task_done_lines) == 3
        @test length(ignored_lines) == 4
        for reason in (
            "task_mismatch",
            "job_mismatch",
            "untracked_endpoint",
            "no_assignment"
        )
            @test count(line -> occursin("reason=$reason", line), ignored_lines) == 1
        end
    end
    println("STEP4_RESULT=PASS_DONE_IDENTITY")
finally
    stop_conductor_log_writer!()
    reset_done_test_state!()
    rm(STEP4_ARTIFACT_DIR; recursive=true, force=true)
end
