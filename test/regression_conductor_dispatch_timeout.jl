using Test

artifact_dir = if haskey(ENV, "SYNCOPADE_TEST_ARTIFACT_DIR")
    abspath(ENV["SYNCOPADE_TEST_ARTIFACT_DIR"])
else
    mktempdir(; prefix="syncopade-dispatch-timeout-")
end
mkpath(artifact_dir)
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(artifact_dir, "conductor_events.csv")

include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))
include(joinpath(@__DIR__, "fixtures", "conductor_controlled_worker.jl"))
using .ConductorControlledWorker

function reset_dispatch_timeout_state!()
    stop_conductor_log_writer!()
    lock(task_queue_lock) do
        empty!(task_queue)
    end
    lock(task_runtime_states_lock) do
        empty!(task_runtime_states)
        empty!(task_acceptance_windows)
    end
    lock(node_states_lock) do
        empty!(node_states)
    end
    return nothing
end

function timeout_task(task_id::String, timeout_seconds::Float64)::ConductorTask
    return ConductorTask(
        task_id,
        "127.0.0.1",
        1,
        "controlled_source",
        "ControlledModule",
        "controlled_function",
        ["arg-1"],
        0,
        timeout_seconds
    )
end

function wait_for_condition(predicate::Function, timeout::Float64, label::String)
    wait_result = Base.timedwait(predicate, timeout; pollint=0.01)
    wait_result === :timed_out && error("timeout waiting for $label")
    return nothing
end

function request_count(worker::ControlledWorker)::Int
    return count(entry -> entry.event == :request && entry.kind == :job, worker_history(worker))
end

function timeout_done_payload(
    task_id::String,
    job_id::String,
    node::NODES;
    status::String="OK",
    error_message::String="none"
)::String
    return join(
        String[
            "DONE",
            task_id,
            job_id,
            node.IP,
            string(node.port),
            status,
            "2026-09-09T00:00:00.000",
            "2026-09-09T00:00:01.000",
            "true",
            error_message,
        ],
        "|"
    )
end

@testset "Conductor Dispatch Outcome Unknown" begin
    reset_dispatch_timeout_state!()

    late_ack_worker = start_controlled_worker()
    try
        late_ack_node = NODES(string(late_ack_worker.ip), late_ack_worker.port, "late-ack")
        late_ack_task = timeout_task("late-ack-task", 5.0)
        enqueue_task!(late_ack_task)
        set_node_state!(late_ack_node, NODE_IDLE)

        run_dispatch_cycle!(
            [late_ack_node];
            dispatch_timeout_seconds=0.05
        )
        @test wait_for_request(late_ack_worker, :job).kind == :job
        unknown = get_task_runtime_state(late_ack_task.task_id)
        @test unknown.state == TASK_DISPATCH_UNKNOWN
        @test queue_len() == 0
        reserved = get_node_runtime_state(late_ack_node)
        @test reserved.state == NODE_RESERVED
        @test reserved.task_id == late_ack_task.task_id
        @test isempty(reserved.job_id)
        @test request_count(late_ack_worker) == 1

        run_dispatch_cycle!(
            [late_ack_node];
            dispatch_timeout_seconds=0.05
        )
        sleep(0.05)
        @test request_count(late_ack_worker) == 1
        respond_job!(late_ack_worker, "OK|STARTED|late-job")
        wait_for_condition(
            () -> begin
                task_state = get_task_runtime_state(late_ack_task.task_id)
                node_state = get_node_runtime_state(late_ack_node)
                task_state.state == TASK_RUNNING &&
                    task_state.job_id == "late-job" &&
                    node_state.state == NODE_BUSY &&
                    node_state.task_id == late_ack_task.task_id &&
                    node_state.job_id == "late-job"
            end,
            1.0,
            "late ACK running state"
        )
        @test request_count(late_ack_worker) == 1
        @test handle_done_payload(timeout_done_payload(
            late_ack_task.task_id,
            "late-job",
            late_ack_node
        ))
        @test get_task_runtime_state(late_ack_task.task_id).terminal_kind == "WORKER_DONE_OK"
    finally
        stop_controlled_worker!(late_ack_worker)
    end

    reset_dispatch_timeout_state!()
    early_done_worker = start_controlled_worker()
    try
        early_done_node = NODES(string(early_done_worker.ip), early_done_worker.port, "early-done")
        early_done_task = timeout_task("early-done-task", 5.0)
        enqueue_task!(early_done_task)
        set_node_state!(early_done_node, NODE_IDLE)
        run_dispatch_cycle!(
            [early_done_node];
            dispatch_timeout_seconds=0.05
        )
        @test wait_for_request(early_done_worker, :job).kind == :job
        @test get_task_runtime_state(early_done_task.task_id).state == TASK_DISPATCH_UNKNOWN
        @test handle_done_payload(timeout_done_payload(
            early_done_task.task_id,
            "early-done-job",
            early_done_node
        ))
        terminal_before_ack = get_task_runtime_state(early_done_task.task_id)
        @test terminal_before_ack.state == TASK_TERMINAL
        @test terminal_before_ack.job_id == "early-done-job"
        respond_job!(early_done_worker, "OK|STARTED|early-done-job")
        wait_for_condition(
            () -> count(entry -> entry.event == :response, worker_history(early_done_worker)) == 1,
            1.0,
            "early DONE delayed ACK response"
        )
        sleep(0.05)
        @test get_task_runtime_state(early_done_task.task_id) == terminal_before_ack
        @test get_node_state(early_done_node) == NODE_IDLE
        @test request_count(early_done_worker) == 1
    finally
        stop_controlled_worker!(early_done_worker)
    end

    reset_dispatch_timeout_state!()
    late_busy_worker = start_controlled_worker()
    try
        late_busy_node = NODES(string(late_busy_worker.ip), late_busy_worker.port, "late-busy")
        late_busy_task = timeout_task("late-busy-task", 5.0)
        enqueue_task!(late_busy_task)
        set_node_state!(late_busy_node, NODE_IDLE)
        run_dispatch_cycle!(
            [late_busy_node];
            dispatch_timeout_seconds=0.05
        )
        @test wait_for_request(late_busy_worker, :job).kind == :job
        @test get_task_runtime_state(late_busy_task.task_id).state == TASK_DISPATCH_UNKNOWN
        respond_job!(late_busy_worker, "ERROR|BUSY")
        wait_for_condition(
            () -> begin
                task_state = get_task_runtime_state(late_busy_task.task_id)
                task_state.state == TASK_QUEUED && queue_len() == 1
            end,
            1.0,
            "late BUSY queue state"
        )
        late_busy_node_state = get_node_runtime_state(late_busy_node)
        @test late_busy_node_state.state == NODE_BUSY
        @test isempty(late_busy_node_state.task_id)
        @test isempty(late_busy_node_state.job_id)
        @test only(lock(task_queue_lock) do
            copy(task_queue)
        end).task_id == late_busy_task.task_id
        @test request_count(late_busy_worker) == 1
    finally
        stop_controlled_worker!(late_busy_worker)
    end

    reset_dispatch_timeout_state!()
    deadline_worker = start_controlled_worker()
    try
        deadline_node = NODES(string(deadline_worker.ip), deadline_worker.port, "deadline")
        deadline_task = timeout_task("unknown-at-deadline-task", 0.5)
        enqueue_task!(deadline_task)
        set_node_state!(deadline_node, NODE_IDLE)
        run_dispatch_cycle!(
            [deadline_node];
            dispatch_timeout_seconds=0.03
        )
        @test wait_for_request(deadline_worker, :job).kind == :job
        @test get_task_runtime_state(deadline_task.task_id).state == TASK_DISPATCH_UNKNOWN
        sleep(0.6)
        expire_waiting_tasks!()
        deadline_terminal = get_task_runtime_state(deadline_task.task_id)
        @test deadline_terminal.state == TASK_TERMINAL
        @test deadline_terminal.terminal_kind == "DISPATCH_OUTCOME_UNKNOWN"
        @test deadline_terminal.reason == "worker_acceptance_outcome_unknown_at_deadline"
        @test get_node_state(deadline_node) == NODE_DOWN
        @test queue_len() == 0
        @test request_count(deadline_worker) == 1
    finally
        stop_controlled_worker!(deadline_worker)
    end

    stop_conductor_log_writer!()
    log_lines = readlines(ENV["SYNCOPADE_CONDUCTOR_LOG"])
    @test count(line -> occursin("\"DISPATCH_OUTCOME_UNKNOWN_PENDING\"", line), log_lines) == 4
    @test count(line -> occursin("\"DISPATCH_LATE_ACK\"", line), log_lines) == 1
    @test count(line -> occursin("\"DISPATCH_LATE_BUSY\"", line), log_lines) == 1
    @test count(line -> occursin("\"DISPATCH_OUTCOME_UNKNOWN\"", line), log_lines) == 1
    @test count(line -> occursin("\"DISPATCH_FAILED\"", line), log_lines) == 0
    @test count(line -> occursin("\"TASK_REQUEUED\"", line), log_lines) == 0
end

reset_dispatch_timeout_state!()
println("STEP8_DISPATCH_RESULT=PASS_OUTCOME_UNKNOWN")
println("STEP8_DISPATCH_ARTIFACT_DIR=", artifact_dir)
