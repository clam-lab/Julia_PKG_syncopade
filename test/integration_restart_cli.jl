include(joinpath(@__DIR__, "listener_test_support.jl"))
include(joinpath(@__DIR__, "..", "src", "Syncopade.jl"))
using .Syncopade: query_server_runtime, restart_server_executor, ServerManagementProtocolError, ServerManagementTransportError

function run_restart_cli(args, dir)
    output, errors = joinpath(dir, "cli.stdout"), joinpath(dir, "cli.stderr")
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__, "..", "scripts", "restart_server.jl")) $args`
    process = run(pipeline(ignorestatus(command); stdout=output, stderr=errors))
    @test isempty(read(errors, String))
    return process.exitcode, read(output, String)
end

@testset "Single restart API and real CLI" begin
    with_test_listener() do handle, dir, audit
        before = query_server_runtime("127.0.0.1"; server_port=handle.port)
        code, output = run_restart_cli(["127.0.0.1", string(handle.port)], dir)
        @test code == 0
        @test occursin("status=success", output)
        @test occursin(before.server_id, output)
        after = query_server_runtime("127.0.0.1"; server_port=handle.port)
        @test after.server_id != before.server_id
        @test after.listener_id == before.listener_id
        @test occursin(after.server_id, output)
        result = restart_server_executor("127.0.0.1"; server_port=handle.port, expected_listener_id=before.listener_id, expected_server_id=before.server_id)
        @test result.status == :id_mismatch
        reservation = runtime_reserve_job!(handle.supervisor.runtime, string(uuid4()))
        try
            code, output = run_restart_cli(["127.0.0.1", string(handle.port)], dir)
            @test code == 2
            @test occursin("status=busy", output)
        finally
            runtime_finish_job!(handle.supervisor.runtime, reservation.listener_id, reservation.server_id, reservation.job_id)
        end
        @test run_restart_cli(String[], dir)[1] == 64
        @test run_restart_cli(["--help"], dir)[1] == 0
    end
end

@testset "Timeout retains unknown outcome and closes sockets" begin
    mktempdir() do gates
        entered, release = joinpath(gates, "entered"), joinpath(gates, "release")
        with_test_listener(script=joinpath(@__DIR__, "fixtures", "executor_lifecycle_probe.jl"),
            extra_env=Dict("SYNCOPADE_LIFECYCLE_FIXTURE" => "delayed_stop", "SYNCOPADE_STOP_ENTERED" => entered,
                "SYNCOPADE_STOP_RELEASE" => release)) do handle, dir, audit
            before = query_server_runtime("127.0.0.1"; server_port=handle.port)
            try
                result = restart_server_executor("127.0.0.1"; server_port=handle.port,
                    expected_listener_id=before.listener_id, expected_server_id=before.server_id, timeout=0.2)
                @test result.status == :unknown
                @test result.request_sent
                @test query_server_runtime("127.0.0.1"; server_port=handle.port).state == :restarting
            finally
                write(release, "release")
            end
            wait_listener_state(handle, :idle)
            after = query_server_runtime("127.0.0.1"; server_port=handle.port)
            @test after.listener_id == before.listener_id
            @test after.server_id != before.server_id
            @test after.ready
        end
    end
    listener = listen(ip"127.0.0.1", 0)
    port = getsockname(listener)[2]
    listener_id, server_id = string(uuid4()), string(uuid4())
    peer = @async begin
        socket = accept(listener)
        try
            row = readline(socket)
            @test occursin("RESTART|1|$listener_id|$server_id", row)
            @test eof(socket)  # Timeout must close the caller's end; no re-send.
        finally
            close(socket)
        end
    end
    try
        result = restart_server_executor("127.0.0.1"; server_port=port, expected_listener_id=listener_id, expected_server_id=server_id, timeout=0.2)
        @test result.status == :unknown
        @test result.request_sent
        @test result.runtime === nothing
        wait(peer)
    finally
        close(listener)
    end
    @test restart_server_executor("127.0.0.1"; server_port=port, expected_listener_id=listener_id, expected_server_id=server_id, timeout=0.2).status == :transport_error
    legacy = listen(ip"127.0.0.1", 0)
    task = @async begin
        for _ in 1:2
            socket = accept(legacy)
            @test checksum(readline(socket))[2] == "RUNTIME"
            println(socket, "ERROR|UNKNOWN_COMMAND")
            close(socket)
        end
    end
    try
        @test_throws ServerManagementProtocolError query_server_runtime("127.0.0.1"; server_port=getsockname(legacy)[2], timeout=1)
        mktempdir() do dir
            code, output = run_restart_cli(["127.0.0.1", string(getsockname(legacy)[2])], dir)
            @test code == 3
            @test occursin("status=query_failed", output)
        end
        wait(task)
    finally
        close(legacy)
    end
end
