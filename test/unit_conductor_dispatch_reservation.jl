using Test

const STEP3_ARTIFACT_DIR = mktempdir()
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(STEP3_ARTIFACT_DIR, "conductor_events.csv")

include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))
include(joinpath(@__DIR__, "fixtures", "conductor_controlled_worker.jl"))
using .ConductorControlledWorker

function reset_dispatch_reservation_state!()
    lock(task_queue_lock) do
        empty!(task_queue)
    end
    lock(node_states_lock) do
        empty!(node_states)
    end
    return nothing
end

function make_dispatch_test_task(task_id::String)::ConductorTask
    return ConductorTask(
        task_id,
        "127.0.0.1",
        1,
        "controlled_source",
        "ControlledModule",
        "controlled_function",
        ["arg-1"],
        0
    )
end

worker = nothing
try
    @testset "Conductor Dispatch Reservation" begin
        reset_dispatch_reservation_state!()
        nodes = [
            NODES("127.0.0.1", 18101, "A"),
            NODES("127.0.0.1", 18102, "B"),
            NODES("127.0.0.1", 18103, "C")
        ]
        set_node_state!(nodes[1], NODE_IDLE)
        set_node_state!(nodes[2], NODE_BUSY)
        set_node_state!(nodes[3], NODE_IDLE)

        selected = reserve_idle_node_right_to_left!(nodes, "task-right")
        @test selected == nodes[3]
        @test node_reserved_for_task(nodes[3], "task-right")
        @test Set(idle_node_endpoints()) == Set(["127.0.0.1:18101"])

        selected_next = reserve_idle_node_right_to_left!(nodes, "task-next")
        @test selected_next == nodes[1]
        @test node_reserved_for_task(nodes[1], "task-next")
        @test isempty(idle_node_endpoints())
        @test reserve_idle_node_right_to_left!(nodes, "task-none") === nothing
        @test_throws ArgumentError reserve_idle_node_right_to_left!(nodes, "")

        reset_dispatch_reservation_state!()
        concurrent_node = NODES("127.0.0.1", 18104, "concurrent")
        set_node_state!(concurrent_node, NODE_IDLE)
        gate = Channel{Nothing}(2)
        reserve_a = Threads.@spawn begin
            take!(gate)
            reserve_idle_node_right_to_left!([concurrent_node], "task-a")
        end
        reserve_b = Threads.@spawn begin
            take!(gate)
            reserve_idle_node_right_to_left!([concurrent_node], "task-b")
        end
        put!(gate, nothing)
        put!(gate, nothing)
        concurrent_results = (fetch(reserve_a), fetch(reserve_b))
        @test count(result -> result !== nothing, concurrent_results) == 1
        @test count(result -> result === nothing, concurrent_results) == 1
        concurrent_state = get_node_runtime_state(concurrent_node)
        @test concurrent_state.state == NODE_RESERVED
        @test concurrent_state.task_id in ("task-a", "task-b")
        @test isempty(concurrent_state.job_id)
        @test isempty(idle_node_endpoints())

        reset_dispatch_reservation_state!()
        worker = start_controlled_worker()
        worker_node = NODES(string(worker.ip), worker.port, "controlled-worker")

        success_task = make_dispatch_test_task("task-success")
        set_node_state!(worker_node, NODE_IDLE)
        enqueue_task!(success_task)
        respond_job!(worker, "OK|STARTED|job-success")
        run_dispatch_cycle!([worker_node])
        @test queue_len() == 0
        success_state = get_node_runtime_state(worker_node)
        @test success_state.state == NODE_BUSY
        @test success_state.task_id == success_task.task_id
        @test success_state.job_id == "job-success"

        reset_dispatch_reservation_state!()
        busy_task = make_dispatch_test_task("task-busy")
        set_node_state!(worker_node, NODE_IDLE)
        enqueue_task!(busy_task)
        respond_job!(worker, "ERROR|BUSY")
        run_dispatch_cycle!([worker_node])
        busy_state = get_node_runtime_state(worker_node)
        @test busy_state.state == NODE_BUSY
        @test isempty(busy_state.task_id)
        @test isempty(busy_state.job_id)
        @test queue_len() == 1
        queued_busy = pop_task!()
        @test queued_busy !== nothing
        @test queued_busy.task_id == busy_task.task_id
        @test queued_busy.retry_count == 0

        stop_conductor_log_writer!()
        log_lines = readlines(ENV["SYNCOPADE_CONDUCTOR_LOG"])
        @test any(
            line -> occursin("\"NODE_RESERVED\",\"task-success\"", line),
            log_lines
        )
        @test any(
            line -> occursin("\"DISPATCH_OK\",\"task-success\"", line) &&
                occursin("\"job-success\"", line),
            log_lines
        )
        @test any(
            line -> occursin("\"NODE_RESERVED\",\"task-busy\"", line),
            log_lines
        )
        @test any(
            line -> occursin("\"DISPATCH_BUSY\",\"task-busy\"", line),
            log_lines
        )

    end
    println("STEP3_RESULT=PASS_ATOMIC_DISPATCH_RESERVATION")
finally
    stop_conductor_log_writer!()
    worker === nothing || stop_controlled_worker!(worker)
    reset_dispatch_reservation_state!()
    rm(STEP3_ARTIFACT_DIR; recursive=true, force=true)
end
