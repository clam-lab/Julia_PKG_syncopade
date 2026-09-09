using Test

artifact_dir = if haskey(ENV, "SYNCOPADE_TEST_ARTIFACT_DIR")
    abspath(ENV["SYNCOPADE_TEST_ARTIFACT_DIR"])
else
    mktempdir(; prefix="syncopade-stale-idle-")
end
mkpath(artifact_dir)
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(artifact_dir, "conductor_events.csv")

include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))
include(joinpath(@__DIR__, "fixtures", "conductor_controlled_worker.jl"))
using .ConductorControlledWorker

function wait_for_completion(task::Task, timeout::Float64, label::String)
    wait_result = Base.timedwait(() -> istaskdone(task), timeout; pollint=0.01)
    wait_result === :timed_out && error("timeout waiting for $label")
    return fetch(task)
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

@testset "Reproduce stale idle rollback" begin
    worker = start_controlled_worker()
    node = NODES(string(worker.ip), worker.port, "controlled-worker")
    refresh_task = nothing
    try
        lock(node_states_lock) do
            empty!(node_states)
        end
        set_node_state!(node, NODE_IDLE)
        @test get_node_state(node) == NODE_IDLE

        refresh_task = @async refresh_states_until_idle!([node]; timeout=2.0)
        status_request = wait_for_request(worker, :status)
        @test status_request.value == "STATUS"
        @test !istaskdone(refresh_task)

        set_node_state!(node, NODE_BUSY)
        @test get_node_state(node) == NODE_BUSY
        busy_confirmed_ns = time_ns()
        @test !istaskdone(refresh_task)

        respond_status!(worker, "STATUS|idle")
        @test wait_for_completion(refresh_task, 2.0, "stale STATUS refresh")
        @test get_node_state(node) == NODE_IDLE

        history = wait_for_history_count(worker, 2)
        request_entries = filter(entry -> entry.event == :request, history)
        response_entries = filter(entry -> entry.event == :response, history)
        @test length(request_entries) == 1
        @test length(response_entries) == 1
        @test only(request_entries).kind == :status
        @test only(request_entries).value == "STATUS"
        @test only(response_entries).kind == :status
        @test only(response_entries).value == "STATUS|idle"
        @test only(request_entries).recorded_ns < busy_confirmed_ns
        @test busy_confirmed_ns < only(response_entries).recorded_ns

        stop_conductor_log_writer!()
        log_text = read(ENV["SYNCOPADE_CONDUCTOR_LOG"], String)
        down_idle = findfirst("\"down\",\"idle\"", log_text)
        idle_busy = findfirst("\"idle\",\"busy\"", log_text)
        busy_idle = findfirst("\"busy\",\"idle\"", log_text)
        @test down_idle !== nothing
        @test idle_busy !== nothing
        @test busy_idle !== nothing
        @test first(down_idle) < first(idle_busy) < first(busy_idle)
    finally
        stop_conductor_log_writer!()
        stop_controlled_worker!(worker)
        lock(node_states_lock) do
            empty!(node_states)
        end
    end
end

println("STEP2_RESULT=PASS_REPRODUCED_STALE_IDLE")
println("STEP2_ARTIFACT_DIR=", artifact_dir)
