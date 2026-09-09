using Test
using Sockets

artifact_dir = if haskey(ENV, "SYNCOPADE_TEST_ARTIFACT_DIR")
    abspath(ENV["SYNCOPADE_TEST_ARTIFACT_DIR"])
else
    mktempdir(; prefix="syncopade-task-lifecycle-")
end
mkpath(artifact_dir)
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(artifact_dir, "conductor_events.csv")

include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))

function reset_task_lifecycle_test_state!()
    stop_conductor_log_writer!()
    lock(task_queue_lock) do
        empty!(task_queue)
    end
    lock(task_runtime_states_lock) do
        empty!(task_runtime_states)
    end
    lock(node_states_lock) do
        empty!(node_states)
    end
end

function lifecycle_test_task(task_id::String, callback_port::Int=1)::ConductorTask
    return ConductorTask(
        task_id,
        "127.0.0.1",
        callback_port,
        "source",
        "ModuleName",
        "function_name",
        String[],
        0
    )
end

@testset "Conductor Task Lifecycle" begin
    reset_task_lifecycle_test_state!()
    try
        allowed_pairs = Set([
            (TASK_QUEUED, TASK_RESERVED),
            (TASK_QUEUED, TASK_TERMINAL),
            (TASK_RESERVED, TASK_QUEUED),
            (TASK_RESERVED, TASK_RUNNING),
            (TASK_RESERVED, TASK_DISPATCH_UNKNOWN),
            (TASK_RESERVED, TASK_TERMINAL),
            (TASK_RUNNING, TASK_TERMINAL),
            (TASK_DISPATCH_UNKNOWN, TASK_RUNNING),
            (TASK_DISPATCH_UNKNOWN, TASK_TERMINAL),
        ])
        for current in TASK_RUNTIME_STATES, next_state in TASK_RUNTIME_STATES
            @test task_transition_allowed(current, next_state) == (
                (current, next_state) in allowed_pairs
            )
        end

        @test get_task_runtime_state("unknown-task") === nothing
        @test !mark_task_reserved!("unknown-reserved")
        @test !mark_task_running!("unknown-running", "job-unknown")
        @test !mark_task_dispatch_unknown!("unknown-dispatch")
        @test !mark_task_terminal!("unknown-terminal", "UNKNOWN", "not registered")

        @test mark_task_queued!("queued-to-reserved")
        queued = get_task_runtime_state("queued-to-reserved")
        @test queued == TaskRuntimeState(TASK_QUEUED, UInt64(1), "", "", "")
        @test mark_task_queued!("queued-to-reserved")
        @test get_task_runtime_state("queued-to-reserved") == queued
        @test mark_task_reserved!("queued-to-reserved")
        @test get_task_runtime_state("queued-to-reserved").generation == UInt64(2)
        @test mark_task_queued!("queued-to-reserved")
        @test get_task_runtime_state("queued-to-reserved").generation == UInt64(3)

        @test mark_task_queued!("reserved-to-running")
        @test mark_task_reserved!("reserved-to-running")
        @test mark_task_running!("reserved-to-running", "job-running")
        running = get_task_runtime_state("reserved-to-running")
        @test running.state == TASK_RUNNING
        @test running.job_id == "job-running"
        @test running.generation == UInt64(3)

        @test mark_task_queued!("reserved-to-unknown")
        @test mark_task_reserved!("reserved-to-unknown")
        @test mark_task_dispatch_unknown!("reserved-to-unknown")
        @test get_task_runtime_state("reserved-to-unknown").state == TASK_DISPATCH_UNKNOWN
        @test mark_task_running!("reserved-to-unknown", "job-late-ack")
        @test get_task_runtime_state("reserved-to-unknown").job_id == "job-late-ack"

        for (task_id, before_terminal, job_id) in (
            ("queued-terminal", TASK_QUEUED, ""),
            ("reserved-terminal", TASK_RESERVED, ""),
            ("running-terminal", TASK_RUNNING, "job-terminal"),
            ("unknown-terminal-path", TASK_DISPATCH_UNKNOWN, ""),
        )
            @test mark_task_queued!(task_id)
            if before_terminal in (TASK_RESERVED, TASK_RUNNING, TASK_DISPATCH_UNKNOWN)
                @test mark_task_reserved!(task_id)
            end
            if before_terminal == TASK_RUNNING
                @test mark_task_running!(task_id, job_id)
            elseif before_terminal == TASK_DISPATCH_UNKNOWN
                @test mark_task_dispatch_unknown!(task_id)
            end
            @test mark_task_terminal!(task_id, "FIRST_TERMINAL", "first reason")
            terminal = get_task_runtime_state(task_id)
            @test terminal.state == TASK_TERMINAL
            @test terminal.job_id == job_id
            @test terminal.terminal_kind == "FIRST_TERMINAL"
            @test terminal.reason == "first reason"
            @test !mark_task_terminal!(task_id, "SECOND_TERMINAL", "second reason")
            @test !mark_task_queued!(task_id)
            @test !mark_task_reserved!(task_id)
            @test !mark_task_running!(task_id, "job-after-terminal")
            @test !mark_task_dispatch_unknown!(task_id)
            @test get_task_runtime_state(task_id) == terminal
        end

        @test mark_task_queued!("forbidden-from-queued")
        @test !mark_task_running!("forbidden-from-queued", "job")
        @test !mark_task_dispatch_unknown!("forbidden-from-queued")
        @test get_task_runtime_state("forbidden-from-queued").state == TASK_QUEUED

        @test mark_task_queued!("forbidden-from-running")
        @test mark_task_reserved!("forbidden-from-running")
        @test mark_task_running!("forbidden-from-running", "job")
        @test !mark_task_queued!("forbidden-from-running")
        @test !mark_task_reserved!("forbidden-from-running")
        @test !mark_task_dispatch_unknown!("forbidden-from-running")
        @test get_task_runtime_state("forbidden-from-running").state == TASK_RUNNING

        @test_throws ArgumentError mark_task_queued!("")
        @test_throws ArgumentError transition_task_state!("bad-state", :invalid)
        @test_throws ArgumentError transition_task_state!(
            "bad-running",
            TASK_RUNNING;
            job_id=""
        )
        @test_throws ArgumentError transition_task_state!(
            "bad-queued-fields",
            TASK_QUEUED;
            job_id="unexpected"
        )
        @test_throws ArgumentError transition_task_state!(
            "bad-terminal-kind",
            TASK_TERMINAL;
            terminal_kind=""
        )

        exhausted = lifecycle_test_task("retry-exhausted")
        enqueue_task!(exhausted)
        @test pop_task!() === exhausted
        @test mark_task_reserved!(exhausted.task_id)
        exhausted_at_limit = ConductorTask(
            exhausted.task_id,
            exhausted.coordinator_ip,
            exhausted.coordinator_port,
            exhausted.source,
            exhausted.module_name,
            exhausted.function_name,
            exhausted.args,
            3
        )
        requeue_with_retry!(exhausted_at_limit; max_retry=3)
        exhausted_state = get_task_runtime_state(exhausted.task_id)
        @test exhausted_state.state == TASK_TERMINAL
        @test exhausted_state.terminal_kind == "MAX_RETRY_EXCEEDED"
        @test exhausted_state.reason == "max_retry_exceeded"
        @test queue_len() == 0

        done_task_id = "done-integration"
        done_job_id = "done-job"
        done_node = NODES("127.0.0.1", 8198, "done-node")
        @test mark_task_queued!(done_task_id)
        @test mark_task_reserved!(done_task_id)
        @test mark_task_running!(done_task_id, done_job_id)
        set_node_state!(done_node, NODE_IDLE)
        @test try_reserve_node!(done_node, done_task_id)
        @test mark_node_running!(done_node, done_task_id, done_job_id)
        done_payload = join(
            String[
                "DONE",
                done_task_id,
                done_job_id,
                done_node.IP,
                string(done_node.port),
                "ERROR",
                "2026-09-09T00:00:00.000",
                "2026-09-09T00:00:01.000",
                "false",
                "RUNTIME_ERROR",
                "controlled failure",
            ],
            "|"
        )
        @test handle_done_payload(done_payload)
        done_state = get_task_runtime_state(done_task_id)
        @test done_state.state == TASK_TERMINAL
        @test done_state.job_id == done_job_id
        @test done_state.terminal_kind == "WORKER_DONE_ERROR"
        @test done_state.reason == "RUNTIME_ERROR|controlled failure"
        @test !handle_done_payload(done_payload)
        @test get_task_runtime_state(done_task_id) == done_state
        parsed_done = parse_conductor_task_status_response(
            task_status_response_payload(done_task_id)
        )
        @test parsed_done isa KnownConductorTaskStatus
        @test parsed_done.reason == "RUNTIME_ERROR|controlled failure"

        callback_server = listen(IPv4("127.0.0.1"), 0)
        _, callback_port_u = getsockname(callback_server)
        callback_port = Int(callback_port_u)
        callback_accept = @async try
            sock = accept(callback_server)
            close(sock)
            true
        catch
            false
        end

        inspected_task = lifecycle_test_task("inspect-only", callback_port)
        enqueue_task!(inspected_task)
        inspected_node = NODES("127.0.0.1", 8199, "inspect-node")
        set_node_state!(inspected_node, NODE_IDLE)
        queue_before = lock(task_queue_lock) do
            copy(task_queue)
        end
        node_before = get_node_runtime_state(inspected_node)
        state_before = get_task_runtime_state(inspected_task.task_id)

        known_payload = task_status_response_payload(inspected_task.task_id)
        unknown_payload = task_status_response_payload("missing-task")

        @test known_payload == "TASK_STATUS|KNOWN|inspect-only|queued|||"
        @test unknown_payload == "TASK_STATUS|UNKNOWN|missing-task"
        @test lock(task_queue_lock) do
            task_queue == queue_before
        end
        @test get_node_runtime_state(inspected_node) == node_before
        @test get_task_runtime_state(inspected_task.task_id) == state_before
        @test Base.timedwait(() -> istaskdone(callback_accept), 0.05; pollint=0.01) === :timed_out

        close(callback_server)
        wait(callback_accept)
    finally
        reset_task_lifecycle_test_state!()
    end
end

println("STEP7_RESULT=PASS_TASK_LIFECYCLE")
println("STEP7_ARTIFACT_DIR=", artifact_dir)
