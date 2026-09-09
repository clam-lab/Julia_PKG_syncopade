using Sockets
using Test

artifact_dir = if haskey(ENV, "SYNCOPADE_TEST_ARTIFACT_DIR")
    abspath(ENV["SYNCOPADE_TEST_ARTIFACT_DIR"])
else
    mktempdir(; prefix="syncopade-terminal-callback-unit-")
end
mkpath(artifact_dir)
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(artifact_dir, "conductor_events.csv")

include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))

function reset_terminal_callback_unit_state!()
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

function terminal_test_listener()
    listener = listen(IPv4("127.0.0.1"), 0)
    _, port_unsigned = getsockname(listener)
    return listener, Int(port_unsigned)
end

function terminal_test_task(
    task_id::String,
    callback_port::Int;
    timeout_seconds::Float64=10.0
)::ConductorTask
    return ConductorTask(
        task_id,
        "127.0.0.1",
        callback_port,
        "controlled_source",
        "ControlledModule",
        "controlled_function",
        ["arg-1"],
        0,
        timeout_seconds
    )
end

function accept_terminal_callback(listener)::Task
    return @async begin
        try
            socket = accept(listener)
            try
                wire_message = readline(socket)
                checksum_ok, payload = verify_checksum(wire_message)
                return (connected=true, checksum_ok=checksum_ok, payload=payload)
            finally
                close(socket)
            end
        catch
            return (connected=false, checksum_ok=false, payload="")
        end
    end
end

function fetch_terminal_callback(task::Task, label::String)
    result = Base.timedwait(() -> istaskdone(task), 2.0; pollint=0.01)
    result === :timed_out && error("timeout waiting for $label")
    return fetch(task)
end

function parsed_terminal_callback(callback)
    @test callback.connected
    @test callback.checksum_ok
    return parse_syncopade_result_payload(callback.payload)
end

@testset "Conductor terminal callback unit paths" begin
    reset_terminal_callback_unit_state!()
    try
        closed_listener, closed_port = terminal_test_listener()
        close(closed_listener)
        failed_task = terminal_test_task("callback-failure", closed_port)
        enqueue_task!(failed_task)
        failed_record_snapshot = get_conductor_task_record(failed_task.task_id)
        push!(failed_record_snapshot.args, "snapshot-only-mutation")
        @test get_conductor_task_record(failed_task.task_id).args == ["arg-1"]
        @test pop_task!() === failed_task
        @test mark_task_reserved!(failed_task.task_id)
        @test finalize_conductor_task!(
            failed_task.task_id,
            "MAX_RETRY_EXCEEDED",
            "max_retry_exceeded";
            expected_states=(TASK_RESERVED,)
        )
        failed_notification = get_task_terminal_notification_state(failed_task.task_id)
        @test failed_notification.status == :failed
        @test !failed_notification.callback_ok
        @test !isempty(failed_notification.error)
        failed_status = parse_conductor_task_status_response(
            task_status_response_payload(failed_task.task_id)
        )
        @test failed_status.state == :terminal
        @test failed_status.terminal_kind == "MAX_RETRY_EXCEEDED"
        @test failed_status.reason == "max_retry_exceeded"
        @test !finalize_conductor_task!(
            failed_task.task_id,
            "MAX_RETRY_EXCEEDED",
            "max_retry_exceeded";
            expected_states=(TASK_RESERVED,)
        )

        queue_listener, queue_port = terminal_test_listener()
        queue_accept = accept_terminal_callback(queue_listener)
        other_listener, other_port = terminal_test_listener()
        other_accept = accept_terminal_callback(other_listener)
        queue_task = terminal_test_task(
            "queue-timeout",
            queue_port;
            timeout_seconds=1.0
        )
        other_task = terminal_test_task(
            "queue-live-other-task",
            other_port;
            timeout_seconds=10.0
        )
        enqueue_task!(queue_task; now_ns=UInt64(0))
        enqueue_task!(other_task; now_ns=UInt64(0))
        queue_expiration = expire_waiting_tasks!(; now_ns=UInt64(1_000_000_000))
        @test queue_expiration == (queue_timeout_count=1, outcome_unknown_count=0)
        queue_callback = parsed_terminal_callback(
            fetch_terminal_callback(queue_accept, "queue timeout callback")
        )
        @test queue_callback.task_id == queue_task.task_id
        @test isempty(queue_callback.job_id)
        @test !queue_callback.ok
        @test queue_callback.payload ==
            "QUEUE_TIMEOUT|worker_acceptance_deadline_exceeded"
        @test get_task_runtime_state(queue_task.task_id).state == TASK_TERMINAL
        @test get_task_runtime_state(other_task.task_id).state == TASK_QUEUED
        @test queue_len() == 1
        @test Base.timedwait(
            () -> istaskdone(other_accept),
            0.2;
            pollint=0.01
        ) === :timed_out
        close(queue_listener)
        close(other_listener)
        @test !fetch_terminal_callback(other_accept, "non-target listener cleanup").connected

        late_busy_listener, late_busy_port = terminal_test_listener()
        late_busy_accept = accept_terminal_callback(late_busy_listener)
        late_busy_task = terminal_test_task(
            "late-busy-at-deadline",
            late_busy_port;
            timeout_seconds=1.0
        )
        late_busy_node = NODES("127.0.0.1", 8196, "late-busy-node")
        enqueue_task!(late_busy_task; now_ns=UInt64(0))
        @test pop_task!() === late_busy_task
        set_node_state!(late_busy_node, NODE_IDLE)
        @test try_reserve_node!(late_busy_node, late_busy_task.task_id)
        @test mark_task_reserved!(late_busy_task.task_id)
        @test mark_task_dispatch_unknown!(late_busy_task.task_id)
        dispatch_task = @async (
            job_id="",
            error=SyncopadeWorkerBusyError("ERROR|BUSY")
        )
        wait(dispatch_task)
        clock_values = UInt64[999_999_999, 1_000_000_000]
        watcher = start_unknown_dispatch_watcher!(
            dispatch_task,
            late_busy_task,
            late_busy_node;
            monotonic_clock=() -> popfirst!(clock_values)
        )
        @test fetch(watcher) === nothing
        late_busy_callback = parsed_terminal_callback(
            fetch_terminal_callback(late_busy_accept, "late BUSY deadline callback")
        )
        @test late_busy_callback.task_id == late_busy_task.task_id
        @test late_busy_callback.payload ==
            "QUEUE_TIMEOUT|worker_acceptance_deadline_exceeded"
        @test get_task_runtime_state(late_busy_task.task_id).terminal_kind ==
            "QUEUE_TIMEOUT"
        @test get_node_state(late_busy_node) == NODE_BUSY
        close(late_busy_listener)

        unknown_listener, unknown_port = terminal_test_listener()
        unknown_accept = accept_terminal_callback(unknown_listener)
        unknown_task = terminal_test_task(
            "dispatch-outcome-unknown",
            unknown_port;
            timeout_seconds=1.0
        )
        unknown_node = NODES("127.0.0.1", 8197, "unknown-node")
        enqueue_task!(unknown_task; now_ns=UInt64(0))
        @test pop_task!() === unknown_task
        set_node_state!(unknown_node, NODE_IDLE)
        @test try_reserve_node!(unknown_node, unknown_task.task_id)
        @test mark_task_reserved!(unknown_task.task_id)
        @test mark_task_dispatch_unknown!(unknown_task.task_id)
        unknown_expiration = expire_waiting_tasks!(; now_ns=UInt64(1_000_000_000))
        @test unknown_expiration == (queue_timeout_count=0, outcome_unknown_count=1)
        unknown_callback = parsed_terminal_callback(
            fetch_terminal_callback(unknown_accept, "dispatch unknown callback")
        )
        @test unknown_callback.task_id == unknown_task.task_id
        @test isempty(unknown_callback.job_id)
        @test !unknown_callback.ok
        @test unknown_callback.payload ==
            "DISPATCH_OUTCOME_UNKNOWN|worker_acceptance_outcome_unknown_at_deadline"
        unknown_status = get_task_runtime_state(unknown_task.task_id)
        @test unknown_status.state == TASK_TERMINAL
        @test unknown_status.terminal_kind == "DISPATCH_OUTCOME_UNKNOWN"
        @test get_node_state(unknown_node) == NODE_DOWN
        close(unknown_listener)

        stop_conductor_log_writer!()
        log_lines = readlines(ENV["SYNCOPADE_CONDUCTOR_LOG"])
        event_count(event::String) = count(
            line -> split(line, ','; limit=3)[2] == "\"$event\"",
            log_lines
        )
        @test event_count("TASK_TERMINAL") == 4
        @test event_count("TASK_QUEUE_TIMEOUT") == 2
        @test event_count("DISPATCH_OUTCOME_UNKNOWN") == 1
    finally
        reset_terminal_callback_unit_state!()
    end
end

println("STEP10_UNIT_RESULT=PASS_TERMINAL_CALLBACK_PATHS")
println("STEP10_UNIT_ARTIFACT_DIR=", artifact_dir)
