using Test

artifact_dir = if haskey(ENV, "SYNCOPADE_TEST_ARTIFACT_DIR")
    abspath(ENV["SYNCOPADE_TEST_ARTIFACT_DIR"])
else
    mktempdir(; prefix="syncopade-busy-wait-")
end
mkpath(artifact_dir)
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(artifact_dir, "conductor_events.csv")

include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))
include(joinpath(@__DIR__, "fixtures", "conductor_controlled_worker.jl"))
using .ConductorControlledWorker

const CONTROLLED_TASK_ID = "controlled-busy-wait-task"
const CONTROLLED_JOB_ID = "controlled-job-after-busy"

function queue_snapshot()::Vector{ConductorTask}
    return lock(task_queue_lock) do
        copy(task_queue)
    end
end

function wait_for_history_count(worker::ControlledWorker, count::Int; timeout::Float64=2.0)
    wait_result = Base.timedwait(
        () -> length(worker_history(worker)) >= count,
        timeout;
        pollint=0.01,
    )
    wait_result === :timed_out && error("timeout waiting for $count worker history entries")
    return worker_history(worker)
end

function count_task_event(lines::Vector{String}, event::String)::Int
    needle = "\"$event\",\"$CONTROLLED_TASK_ID\""
    return count(line -> occursin(needle, line), lines)
end

function controlled_done_payload(node::NODES)::String
    return join(
        String[
            "DONE",
            CONTROLLED_TASK_ID,
            CONTROLLED_JOB_ID,
            node.IP,
            string(node.port),
            "OK",
            "2026-09-09T00:00:00.000",
            "2026-09-09T00:00:01.000",
            "true",
            "none"
        ],
        "|"
    )
end

elapsed_seconds = Ref(NaN)

@testset "Keep BUSY task until worker accepts" begin
    worker = start_controlled_worker()
    node = NODES(string(worker.ip), worker.port, "controlled-worker")
    try
        lock(task_queue_lock) do
            empty!(task_queue)
        end
        lock(node_states_lock) do
            empty!(node_states)
        end

        task = ConductorTask(
            CONTROLLED_TASK_ID,
            "127.0.0.1",
            1,
            "controlled_source",
            "ControlledModule",
            "controlled_function",
            ["arg-1"],
            0,
        )
        enqueue_task!(task)
        @test queue_len() == 1

        started_ns = time_ns()
        for _ in 1:3
            respond_job!(worker, "ERROR|BUSY")
            set_node_state!(node, NODE_IDLE)
            @test get_node_state(node) == NODE_IDLE

            run_dispatch_cycle!([node]; max_retry=3)
            busy_state = get_node_runtime_state(node)
            @test busy_state.state == NODE_BUSY
            @test isempty(busy_state.task_id)
            @test isempty(busy_state.job_id)

            queued = queue_snapshot()
            @test length(queued) == 1
            @test only(queued).task_id == CONTROLLED_TASK_ID
            @test only(queued).retry_count == 0
        end

        set_node_state!(node, NODE_IDLE)
        respond_job!(worker, "OK|STARTED|$CONTROLLED_JOB_ID")
        run_dispatch_cycle!([node]; max_retry=3)
        @test queue_len() == 0
        running_state = get_node_runtime_state(node)
        @test running_state.state == NODE_BUSY
        @test running_state.task_id == CONTROLLED_TASK_ID
        @test running_state.job_id == CONTROLLED_JOB_ID

        @test handle_done_payload(controlled_done_payload(node))
        done_state = get_node_runtime_state(node)
        @test done_state.state == NODE_IDLE
        @test isempty(done_state.task_id)
        @test isempty(done_state.job_id)
        elapsed_seconds[] = Float64(time_ns() - started_ns) / 1.0e9

        history = wait_for_history_count(worker, 8)
        request_entries = filter(entry -> entry.event == :request, history)
        response_entries = filter(entry -> entry.event == :response, history)
        @test length(request_entries) == 4
        @test length(response_entries) == 4
        @test all(entry -> entry.kind == :job, request_entries)
        @test all(entry -> entry.kind == :job, response_entries)
        @test all(
            entry -> occursin("__syncopade_meta_task_id=$CONTROLLED_TASK_ID", entry.value),
            request_entries
        )
        @test count(entry -> entry.value == "ERROR|BUSY", response_entries) == 3
        @test count(
            entry -> entry.value == "OK|STARTED|$CONTROLLED_JOB_ID",
            response_entries
        ) == 1

        stop_conductor_log_writer!()
        log_lines = readlines(ENV["SYNCOPADE_CONDUCTOR_LOG"])
        @test count_task_event(log_lines, "DISPATCH_START") == 4
        @test count_task_event(log_lines, "DISPATCH_BUSY") == 3
        @test count_task_event(log_lines, "TASK_REQUEUED_BUSY") == 3
        @test count_task_event(log_lines, "DISPATCH_OK") == 1
        @test count_task_event(log_lines, "TASK_DONE") == 1
        @test count_task_event(log_lines, "DISPATCH_FAILED") == 0
        @test count_task_event(log_lines, "TASK_REQUEUED") == 0
        @test count_task_event(log_lines, "TASK_DROPPED") == 0
        @test count(
            line -> occursin("Unexpected response from server: ERROR|BUSY", line),
            log_lines
        ) == 3
        @test count(
            line -> occursin(
                "\"DISPATCH_START\",\"$CONTROLLED_TASK_ID\",\"0\"",
                line
            ),
            log_lines
        ) == 4
        @test count(
            line -> occursin("\"reserved\",\"down\"", line),
            log_lines
        ) == 0
    finally
        stop_conductor_log_writer!()
        stop_controlled_worker!(worker)
        lock(task_queue_lock) do
            empty!(task_queue)
        end
        lock(node_states_lock) do
            empty!(node_states)
        end
    end
end

println("STEP6_RESULT=PASS_BUSY_WAIT_AND_ACCEPT")
println("STEP6_BUSY_TO_DONE_SECONDS=", elapsed_seconds[])
println("STEP6_ARTIFACT_DIR=", artifact_dir)
