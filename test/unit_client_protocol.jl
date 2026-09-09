using Test

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

@testset "Client Protocol" begin
    accepted_reply = parse_worker_start_response("OK|STARTED|job-123")
    @test accepted_reply isa WorkerStartAccepted
    @test accepted_reply.job_id == "job-123"
    @test accepted_reply.job_id isa String

    busy_reply = parse_worker_start_response("ERROR|BUSY")
    @test busy_reply isa WorkerStartBusy
    @test busy_reply.raw_response == "ERROR|BUSY"

    for malformed in ("OK|STARTED|", "OK|STARTED|job|extra", "ERROR|UNKNOWN")
        error_value = try
            parse_worker_start_response(malformed)
            nothing
        catch caught
            caught
        end
        @test error_value isa SyncopadeWorkerProtocolError
        @test classify_worker_start_error(error_value) == :protocol_error
    end

    @test classify_worker_start_error(SyncopadeWorkerBusyError("ERROR|BUSY")) == :busy
    @test classify_worker_start_error(SyncopadeWorkerStartTimeoutError(3.0)) == :outcome_unknown
    @test classify_worker_start_error(EOFError()) == :transport_error
    @test classify_worker_start_error(ArgumentError("unexpected")) == :unexpected_error

    payload = "ABC|123|xyz"
    msg = add_checksum(payload)
    ok, decoded = verify_checksum(msg)
    @test ok
    @test decoded == payload

    @test !verify_checksum(payload * "|ff")[1]

    nodes = parse_conductor_nodes("NODES|192.168.0.10:8010|192.168.0.11:8011")
    @test nodes == [("192.168.0.10", 8010), ("192.168.0.11", 8011)]

    nodes_with_checksum = parse_conductor_nodes(add_checksum("NODES|192.168.0.20:8020"))
    @test nodes_with_checksum == [("192.168.0.20", 8020)]

    malformed = parse_conductor_nodes("ERROR|UNKNOWN_COMMAND")
    @test isempty(malformed)

    for state in (:queued, :reserved, :dispatch_unknown)
        parsed = parse_conductor_task_status_response(
            "TASK_STATUS|KNOWN|task-$state|$state|||"
        )
        @test parsed isa KnownConductorTaskStatus
        @test parsed.task_id == "task-$state"
        @test parsed.state == state
        @test isempty(parsed.job_id)
        @test isempty(parsed.terminal_kind)
        @test isempty(parsed.reason)
    end

    running_status = parse_conductor_task_status_response(
        "TASK_STATUS|KNOWN|task-running|running|job-running||"
    )
    @test running_status isa KnownConductorTaskStatus
    @test running_status.state == :running
    @test running_status.job_id == "job-running"

    terminal_status = parse_conductor_task_status_response(
        "TASK_STATUS|KNOWN|task-terminal|terminal|job-terminal|WORKER_DONE_ERROR|TYPE|message"
    )
    @test terminal_status isa KnownConductorTaskStatus
    @test terminal_status.state == :terminal
    @test terminal_status.job_id == "job-terminal"
    @test terminal_status.terminal_kind == "WORKER_DONE_ERROR"
    @test terminal_status.reason == "TYPE|message"

    unknown_status = parse_conductor_task_status_response(
        "TASK_STATUS|UNKNOWN|missing-task"
    )
    @test unknown_status isa UnknownConductorTaskStatus
    @test unknown_status.task_id == "missing-task"

    for invalid_status in (
        "TASK_STATUS|KNOWN||queued|||",
        "TASK_STATUS|KNOWN|bad-state|invalid|||",
        "TASK_STATUS|KNOWN|bad-running|running|||",
        "TASK_STATUS|KNOWN|bad-queued-job|queued|job||",
        "TASK_STATUS|KNOWN|bad-terminal|terminal|job||reason",
        "TASK_STATUS|UNKNOWN|",
        "TASK_STATUS|OTHER|task",
    )
        @test_throws ArgumentError parse_conductor_task_status_response(invalid_status)
    end

    bind_ip = IPv4("127.0.0.1")
    server = listen(bind_ip, 0)
    _, port_u = getsockname(server)
    port = Int(port_u)

    received_payload = Ref("")
    server_task = @async begin
        sock = accept(server)
        try
            line = readline(sock)
            ok2, payload2 = verify_checksum(line)
            if !ok2
                println(sock, add_checksum("ERROR|BAD_CHECKSUM"))
                return
            end
            received_payload[] = payload2
            println(sock, add_checksum("OK|CACHE_CLEAR_ALL|3|2|1|7"))
        finally
            close(sock)
            close(server)
        end
    end

    summary = clear_conductor_node_caches("127.0.0.1"; conductor_port=port)
    fetch(server_task)
    @test received_payload[] == "CACHE_CLEAR_ALL"
    @test summary == (total_nodes=3, success_nodes=2, failed_nodes=1, cleared_functions=7)

    status_server = listen(bind_ip, 0)
    _, status_port_u = getsockname(status_server)
    status_port = Int(status_port_u)
    status_request = Ref("")
    status_server_task = @async begin
        sock = accept(status_server)
        try
            line = readline(sock)
            request_ok, request_payload = verify_checksum(line)
            request_ok || error("invalid test request checksum")
            status_request[] = request_payload
            println(
                sock,
                add_checksum("TASK_STATUS|KNOWN|query-task|running|query-job||")
            )
        finally
            close(sock)
            close(status_server)
        end
    end

    queried_status = query_conductor_task_status(
        "127.0.0.1",
        "query-task";
        conductor_port=status_port
    )
    fetch(status_server_task)
    @test status_request[] == "TASK_STATUS|query-task"
    @test queried_status isa KnownConductorTaskStatus
    @test queried_status.task_id == "query-task"
    @test queried_status.state == :running
    @test queried_status.job_id == "query-job"
end
