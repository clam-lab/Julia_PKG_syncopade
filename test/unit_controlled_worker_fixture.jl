using Sockets
using Test

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))
include(joinpath(@__DIR__, "fixtures", "conductor_controlled_worker.jl"))
using .ConductorControlledWorker

@testset "Controlled conductor worker fixture" begin
    worker = start_controlled_worker()
    released_port = worker.port
    try
        status_task = @async query_server_status(string(worker.ip), worker.port)
        status_request = wait_for_request(worker, :status)
        @test status_request.value == "STATUS"
        @test !istaskdone(status_task)
        respond_status!(worker, "STATUS|idle")
        @test fetch(status_task) == "STATUS|idle"

        client = SyncopadeClient(
            string(worker.ip),
            worker.port,
            "127.0.0.1",
            1,
            "controlled_source",
            "ControlledModule",
            "controlled_function",
            ["arg-1"],
        )

        busy_task = @async try
            syncopade_calc_request(client)
        catch error_value
            error_value
        end
        busy_request = wait_for_request(worker, :job)
        @test occursin("controlled_source:ControlledModule:controlled_function", busy_request.value)
        @test !istaskdone(busy_task)
        respond_job!(worker, "ERROR|BUSY")
        busy_error = fetch(busy_task)
        @test busy_error isa SyncopadeWorkerBusyError
        @test classify_worker_start_error(busy_error) == :busy
        @test occursin("ERROR|BUSY", sprint(showerror, busy_error))

        malformed_task = @async try
            syncopade_calc_request(client)
        catch error_value
            error_value
        end
        malformed_request = wait_for_request(worker, :job)
        @test occursin(
            "controlled_source:ControlledModule:controlled_function",
            malformed_request.value
        )
        @test !istaskdone(malformed_task)
        respond_job!(worker, "ERROR|UNEXPECTED")
        malformed_error = fetch(malformed_task)
        @test malformed_error isa SyncopadeWorkerProtocolError
        @test classify_worker_start_error(malformed_error) == :protocol_error

        accepted_task = @async syncopade_calc_request(client)
        accepted_request = wait_for_request(worker, :job)
        @test occursin("controlled_source:ControlledModule:controlled_function", accepted_request.value)
        @test !istaskdone(accepted_task)
        respond_job!(worker, "OK|STARTED|controlled-job-1")
        accepted_job_id = fetch(accepted_task)
        @test accepted_job_id == "controlled-job-1"
        @test accepted_job_id isa String

        closed_listener = listen(IPv4("127.0.0.1"), 0)
        _, closed_port_unsigned = getsockname(closed_listener)
        closed_port = Int(closed_port_unsigned)
        close(closed_listener)
        closed_client = SyncopadeClient(
            "127.0.0.1",
            closed_port,
            "127.0.0.1",
            1,
            "controlled_source",
            "ControlledModule",
            "controlled_function",
            ["arg-1"],
        )
        transport_error = try
            syncopade_calc_request(closed_client)
            nothing
        catch error_value
            error_value
        end
        @test transport_error isa Exception
        @test classify_worker_start_error(transport_error) == :transport_error

        history = worker_history(worker)
        request_entries = filter(entry -> entry.event == :request, history)
        response_entries = filter(entry -> entry.event == :response, history)
        @test getproperty.(request_entries, :kind) == [:status, :job, :job, :job]
        @test getproperty.(response_entries, :kind) == [:status, :job, :job, :job]
        @test getproperty.(response_entries, :value) == [
            "STATUS|idle",
            "ERROR|BUSY",
            "ERROR|UNEXPECTED",
            "OK|STARTED|controlled-job-1",
        ]
        @test getproperty.(request_entries, :request_id) == [1, 2, 3, 4]
        @test getproperty.(response_entries, :request_id) == [1, 2, 3, 4]
    finally
        stop_controlled_worker!(worker)
    end

    rebound = listen(IPv4("127.0.0.1"), released_port)
    close(rebound)
end

println("STEP1_RESULT=PASS_CONTROLLED_WORKER_FIXTURE")
