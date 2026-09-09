using Test
using Sockets

artifact_dir = if haskey(ENV, "SYNCOPADE_TEST_ARTIFACT_DIR")
    abspath(ENV["SYNCOPADE_TEST_ARTIFACT_DIR"])
else
    mktempdir(; prefix="syncopade-queue-deadline-")
end
mkpath(artifact_dir)
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(artifact_dir, "conductor_events.csv")

include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))

function reset_queue_deadline_state!()
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

function deadline_task(task_id::String, timeout_seconds::Float64)::ConductorTask
    return ConductorTask(
        task_id,
        "127.0.0.1",
        1,
        "controlled_source",
        "ControlledModule",
        "controlled_function",
        String[],
        0,
        timeout_seconds
    )
end

@testset "Conductor Queue Acceptance Deadline" begin
    original_env = get(ENV, QUEUE_ACCEPTANCE_TIMEOUT_ENV, nothing)
    try
        delete!(ENV, QUEUE_ACCEPTANCE_TIMEOUT_ENV)
        @test default_queue_acceptance_timeout_seconds() == 14400.0
        legacy = parse_submit_task(
            "SUBMIT|127.0.0.1|9001|source:Module:function|arg"
        )
        @test legacy.acceptance_timeout_seconds == 14400.0

        ENV[QUEUE_ACCEPTANCE_TIMEOUT_ENV] = "7200.5"
        @test default_queue_acceptance_timeout_seconds() == 7200.5
        environment_default = parse_submit_task(
            "SUBMIT|127.0.0.1|source:Module:function"
        )
        @test environment_default.acceptance_timeout_seconds == 7200.5

        per_submit = parse_submit_task(
            "SUBMIT|ACCEPTANCE_TIMEOUT_SECONDS=12.5|127.0.0.1|9001|source:Module:function"
        )
        @test per_submit.acceptance_timeout_seconds == 12.5
        @test per_submit.coordinator_ip == "127.0.0.1"
        @test per_submit.coordinator_port == 9001

        for invalid in ("0", "-1", "NaN", "Inf", "not-a-number")
            ENV[QUEUE_ACCEPTANCE_TIMEOUT_ENV] = invalid
            @test_throws ArgumentError default_queue_acceptance_timeout_seconds()
        end
        delete!(ENV, QUEUE_ACCEPTANCE_TIMEOUT_ENV)
        for invalid in (0.0, -1.0, NaN, Inf)
            @test_throws ArgumentError normalize_acceptance_timeout_seconds(invalid)
        end
        @test_throws ArgumentError parse_submit_task(
            "SUBMIT|ACCEPTANCE_TIMEOUT_SECONDS=|127.0.0.1|source:Module:function"
        )

        @test acceptance_timeout_nanoseconds(1.0e300) == typemax(UInt64)
        @test acceptance_deadline_ns(typemax(UInt64) - UInt64(5), 1.0) == typemax(UInt64)

        submit_server = listen(IPv4("127.0.0.1"), 0)
        _, submit_port_u = getsockname(submit_server)
        submit_port = Int(submit_port_u)
        received_submit = Ref("")
        submit_server_task = @async begin
            socket = accept(submit_server)
            try
                request = readline(socket)
                request_ok, request_payload = verify_checksum(request)
                request_ok || error("invalid SUBMIT checksum")
                received_submit[] = request_payload
                println(socket, add_checksum("OK|QUEUED|wire-task"))
            finally
                close(socket)
                close(submit_server)
            end
        end
        submitted_id = submit_conductor_task(
            "127.0.0.1";
            conductor_port=submit_port,
            coordinator_ip="127.0.0.1",
            coordinator_port=9101,
            source="source",
            module_name="Module",
            function_name="function",
            args=["arg"],
            acceptance_timeout_seconds=7.5
        )
        fetch(submit_server_task)
        @test submitted_id == "wire-task"
        @test received_submit[] ==
            "SUBMIT|ACCEPTANCE_TIMEOUT_SECONDS=7.5|127.0.0.1|9101|source:Module:function|arg"

        reset_queue_deadline_state!()
        started_ns = UInt64(1_000_000_000)
        task = deadline_task("fixed-window", 10.0)
        enqueue_task!(task; now_ns=started_ns)
        window = get_task_acceptance_window(task.task_id)
        @test window == TaskAcceptanceWindow(
            started_ns,
            started_ns + UInt64(10_000_000_000),
            10.0
        )
        @test pop_task!() === task
        @test mark_task_reserved!(task.task_id)
        enqueue_task!(task; now_ns=started_ns + UInt64(5_000_000_000))
        @test get_task_acceptance_window(task.task_id) == window
        before_deadline = expire_waiting_tasks!(; now_ns=window.deadline_ns - UInt64(1))
        @test before_deadline == (queue_timeout_count=0, outcome_unknown_count=0)
        @test queue_len() == 1
        at_deadline = expire_waiting_tasks!(; now_ns=window.deadline_ns)
        @test at_deadline == (queue_timeout_count=1, outcome_unknown_count=0)
        @test queue_len() == 0
        fixed_terminal = get_task_runtime_state(task.task_id)
        @test fixed_terminal.state == TASK_TERMINAL
        @test fixed_terminal.terminal_kind == "QUEUE_TIMEOUT"
        @test fixed_terminal.reason == "worker_acceptance_deadline_exceeded"

        reset_queue_deadline_state!()
        expired_inside = deadline_task("expired-inside-lifo", 1.0)
        live_on_top = deadline_task("live-on-top", 10.0)
        enqueue_task!(expired_inside; now_ns=UInt64(0))
        enqueue_task!(live_on_top; now_ns=UInt64(0))
        lifo_sweep = expire_waiting_tasks!(; now_ns=UInt64(1_000_000_000))
        @test lifo_sweep == (queue_timeout_count=1, outcome_unknown_count=0)
        @test queue_len() == 1
        @test only(lock(task_queue_lock) do
            copy(task_queue)
        end).task_id == live_on_top.task_id
        @test get_task_runtime_state(expired_inside.task_id).terminal_kind == "QUEUE_TIMEOUT"
        @test get_task_runtime_state(live_on_top.task_id).state == TASK_QUEUED

        reset_queue_deadline_state!()
        running_task = deadline_task("long-running", 1.0)
        enqueue_task!(running_task; now_ns=UInt64(0))
        @test pop_task!() === running_task
        @test mark_task_reserved!(running_task.task_id)
        @test mark_task_running!(running_task.task_id, "running-job")
        running_sweep = expire_waiting_tasks!(; now_ns=UInt64(100_000_000_000))
        @test running_sweep == (queue_timeout_count=0, outcome_unknown_count=0)
        @test get_task_runtime_state(running_task.task_id).state == TASK_RUNNING

        stop_conductor_log_writer!()
        log_lines = readlines(ENV["SYNCOPADE_CONDUCTOR_LOG"])
        @test count(line -> occursin("\"TASK_QUEUE_TIMEOUT\"", line), log_lines) == 2
    finally
        if original_env === nothing
            delete!(ENV, QUEUE_ACCEPTANCE_TIMEOUT_ENV)
        else
            ENV[QUEUE_ACCEPTANCE_TIMEOUT_ENV] = original_env
        end
        reset_queue_deadline_state!()
    end
end

println("STEP8_QUEUE_RESULT=PASS_ACCEPTANCE_DEADLINE")
println("STEP8_QUEUE_ARTIFACT_DIR=", artifact_dir)
