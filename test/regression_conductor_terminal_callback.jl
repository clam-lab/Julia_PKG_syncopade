using Sockets
using Test

artifact_dir = if haskey(ENV, "SYNCOPADE_TEST_ARTIFACT_DIR")
    abspath(ENV["SYNCOPADE_TEST_ARTIFACT_DIR"])
else
    mktempdir(; prefix="syncopade-terminal-callback-")
end
mkpath(artifact_dir)
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(artifact_dir, "conductor_events.csv")

include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))

const TERMINAL_CALLBACK_TASK_ID = "controlled-terminal-callback-task"

function reset_terminal_callback_regression_state!()
    stop_conductor_log_writer!()
    lock(task_queue_lock) do
        empty!(task_queue)
    end
    lock(node_states_lock) do
        empty!(node_states)
    end
    lock(task_runtime_states_lock) do
        empty!(task_runtime_states)
        empty!(task_acceptance_windows)
        empty!(conductor_task_records)
        empty!(task_terminal_notifications)
    end
    return nothing
end

function wait_for_terminal_callback_task(
    task::Task,
    timeout::Float64,
    label::String
)
    wait_result = Base.timedwait(() -> istaskdone(task), timeout; pollint=0.01)
    wait_result === :timed_out && error("timeout waiting for $label")
    return fetch(task)
end

@testset "Conductor terminal callback after retry exhaustion" begin
    reset_terminal_callback_regression_state!()
    callback_ip = IPv4("127.0.0.1")
    listener = listen(callback_ip, 0)
    _, callback_port_unsigned = getsockname(listener)
    callback_port = Int(callback_port_unsigned)
    first_accept = @async begin
        socket = accept(listener)
        try
            wire_message = readline(socket)
            checksum_ok, payload = verify_checksum(wire_message)
            return (checksum_ok=checksum_ok, payload=payload)
        finally
            close(socket)
        end
    end
    second_accept = nothing

    try
        task = ConductorTask(
            TERMINAL_CALLBACK_TASK_ID,
            string(callback_ip),
            callback_port,
            "controlled_source",
            "ControlledModule",
            "controlled_function",
            ["arg-1"],
            3,
        )

        enqueue_task!(task)
        @test pop_task!() === task
        @test mark_task_reserved!(task.task_id)
        requeue_with_retry!(task; max_retry=3)

        callback = wait_for_terminal_callback_task(
            first_accept,
            2.0,
            "retry terminal callback"
        )
        @test callback.checksum_ok
        parsed = parse_syncopade_result_payload(callback.payload)
        @test parsed.protocol == :task_result
        @test parsed.task_id == task.task_id
        @test isempty(parsed.job_id)
        @test !parsed.ok
        @test parsed.payload == "MAX_RETRY_EXCEEDED|max_retry_exceeded"

        status = parse_conductor_task_status_response(
            task_status_response_payload(task.task_id)
        )
        @test status isa KnownConductorTaskStatus
        @test status.state == :terminal
        @test status.terminal_kind == "MAX_RETRY_EXCEEDED"
        @test status.reason == "max_retry_exceeded"
        notification = get_task_terminal_notification_state(task.task_id)
        @test notification == TaskTerminalNotificationState(:succeeded, true, "")
        @test queue_len() == 0

        second_accept = @async begin
            try
                socket = accept(listener)
                close(socket)
                return :connected
            catch
                return :closed
            end
        end
        @test !finalize_conductor_task!(
            task.task_id,
            "MAX_RETRY_EXCEEDED",
            "max_retry_exceeded";
            expected_states=(TASK_RESERVED,)
        )
        @test Base.timedwait(
            () -> istaskdone(second_accept),
            0.2;
            pollint=0.01
        ) === :timed_out

        stop_conductor_log_writer!()
        log_lines = readlines(ENV["SYNCOPADE_CONDUCTOR_LOG"])
        @test count(line -> occursin("\"TASK_TERMINAL\"", line), log_lines) == 1
        @test count(line -> occursin("\"TASK_DROPPED\"", line), log_lines) == 1
    finally
        stop_conductor_log_writer!()
        close(listener)
        if second_accept !== nothing
            @test wait_for_terminal_callback_task(
                second_accept,
                2.0,
                "duplicate callback accept cleanup"
            ) == :closed
        end
        reset_terminal_callback_regression_state!()
    end
end

println("STEP10_RESULT=PASS_TERMINAL_CALLBACK")
println("STEP10_ARTIFACT_DIR=", artifact_dir)
