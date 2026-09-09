using Sockets
using Test

artifact_dir = if haskey(ENV, "SYNCOPADE_TEST_ARTIFACT_DIR")
    abspath(ENV["SYNCOPADE_TEST_ARTIFACT_DIR"])
else
    mktempdir(; prefix="syncopade-silent-drop-")
end
mkpath(artifact_dir)
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(artifact_dir, "conductor_events.csv")

include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))

const SILENT_DROP_TASK_ID = "controlled-silent-drop-task"

function wait_for_task_done(task::Task, timeout::Float64, label::String)
    wait_result = Base.timedwait(() -> istaskdone(task), timeout; pollint=0.01)
    wait_result === :timed_out && error("timeout waiting for $label")
    return fetch(task)
end

@testset "Reproduce silent conductor task drop" begin
    callback_ip = IPv4("127.0.0.1")
    listener = listen(callback_ip, 0)
    _, callback_port_unsigned = getsockname(listener)
    callback_port = Int(callback_port_unsigned)
    accepted_task_ids = Set([SILENT_DROP_TASK_ID])
    accept_outcome = Ref{Any}(nothing)
    accept_task = @async begin
        try
            socket = accept(listener)
            return (connected=true, socket=socket, error=nothing)
        catch error_value
            return (connected=false, socket=nothing, error=error_value)
        end
    end

    try
        lock(task_queue_lock) do
            empty!(task_queue)
        end
        lock(node_states_lock) do
            empty!(node_states)
        end

        task = ConductorTask(
            SILENT_DROP_TASK_ID,
            string(callback_ip),
            callback_port,
            "controlled_source",
            "ControlledModule",
            "controlled_function",
            ["arg-1"],
            3,
        )

        requeue_with_retry!(task; max_retry=3)
        @test queue_len() == 0
        @test SILENT_DROP_TASK_ID in accepted_task_ids

        stop_conductor_log_writer!()
        log_lines = readlines(ENV["SYNCOPADE_CONDUCTOR_LOG"])
        drop_needle = "\"TASK_DROPPED\",\"$SILENT_DROP_TASK_ID\",\"3\""
        drop_lines = filter(line -> occursin(drop_needle, line), log_lines)
        @test length(drop_lines) == 1
        @test occursin("max_retry_exceeded", only(drop_lines))

        callback_wait = Base.timedwait(() -> istaskdone(accept_task), 0.5; pollint=0.01)
        @test callback_wait === :timed_out
        @test !istaskdone(accept_task)
        @test SILENT_DROP_TASK_ID in accepted_task_ids
    finally
        stop_conductor_log_writer!()
        try
            close(listener)
        catch
        end
        accept_outcome[] = wait_for_task_done(accept_task, 2.0, "callback accept cleanup")
        if accept_outcome[].socket !== nothing
            try
                close(accept_outcome[].socket)
            catch
            end
        end
        lock(task_queue_lock) do
            empty!(task_queue)
        end
        lock(node_states_lock) do
            empty!(node_states)
        end
    end

    @test !accept_outcome[].connected
    @test accept_outcome[].error isa Exception
    rebound = listen(callback_ip, callback_port)
    close(rebound)
end

println("STEP4_RESULT=PASS_REPRODUCED_SILENT_DROP")
println("STEP4_ARTIFACT_DIR=", artifact_dir)
