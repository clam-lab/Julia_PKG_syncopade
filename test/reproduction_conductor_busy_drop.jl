using Test

artifact_dir = if haskey(ENV, "SYNCOPADE_TEST_ARTIFACT_DIR")
    abspath(ENV["SYNCOPADE_TEST_ARTIFACT_DIR"])
else
    mktempdir(; prefix="syncopade-busy-drop-")
end
mkpath(artifact_dir)
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(artifact_dir, "conductor_events.csv")

include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))
include(joinpath(@__DIR__, "fixtures", "conductor_controlled_worker.jl"))
using .ConductorControlledWorker

const CONTROLLED_TASK_ID = "controlled-busy-drop-task"

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

elapsed_seconds = Ref(NaN)

@testset "Reproduce BUSY retry exhaustion and drop" begin
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
        for cycle in 1:4
            respond_job!(worker, "ERROR|BUSY")
            set_node_state!(node, NODE_IDLE)
            @test get_node_state(node) == NODE_IDLE

            run_dispatch_cycle!([node]; max_retry=3)
            @test get_node_state(node) == NODE_DOWN

            queued = queue_snapshot()
            if cycle <= 3
                @test length(queued) == 1
                @test only(queued).task_id == CONTROLLED_TASK_ID
                @test only(queued).retry_count == cycle
            else
                @test isempty(queued)
                @test queue_len() == 0
            end
        end
        elapsed_seconds[] = Float64(time_ns() - started_ns) / 1.0e9

        history = wait_for_history_count(worker, 8)
        request_entries = filter(entry -> entry.event == :request, history)
        response_entries = filter(entry -> entry.event == :response, history)
        @test length(request_entries) == 4
        @test length(response_entries) == 4
        @test all(entry -> entry.kind == :job, request_entries)
        @test all(entry -> entry.kind == :job, response_entries)
        @test all(entry -> entry.value == "ERROR|BUSY", response_entries)
        @test count(entry -> startswith(entry.value, "OK|STARTED|"), response_entries) == 0

        stop_conductor_log_writer!()
        log_lines = readlines(ENV["SYNCOPADE_CONDUCTOR_LOG"])
        @test count_task_event(log_lines, "DISPATCH_START") == 4
        @test count_task_event(log_lines, "DISPATCH_FAILED") == 4
        @test count_task_event(log_lines, "TASK_REQUEUED") == 3
        @test count_task_event(log_lines, "TASK_DROPPED") == 1
        @test count(line -> occursin("Unexpected response from server: ERROR|BUSY", line), log_lines) == 4
        for retry in 0:3
            @test any(
                line -> occursin(
                    "\"DISPATCH_START\",\"$CONTROLLED_TASK_ID\",\"$retry\"",
                    line,
                ),
                log_lines,
            )
        end
        for retry in 1:3
            @test any(
                line -> occursin(
                    "\"TASK_REQUEUED\",\"$CONTROLLED_TASK_ID\",\"$retry\"",
                    line,
                ),
                log_lines,
            )
        end
        @test any(
            line -> occursin(
                "\"TASK_DROPPED\",\"$CONTROLLED_TASK_ID\",\"3\"",
                line,
            ) && occursin("max_retry_exceeded", line),
            log_lines,
        )
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

println("STEP3_RESULT=PASS_REPRODUCED_BUSY_DROP")
println("STEP3_DISPATCH_TO_DROP_SECONDS=", elapsed_seconds[])
println("STEP3_ARTIFACT_DIR=", artifact_dir)
