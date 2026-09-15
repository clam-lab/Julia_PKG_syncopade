using Test, Sockets, UUIDs
include(joinpath(@__DIR__, "..", "src", "Syncopade.jl"))
using .Syncopade
include(joinpath(@__DIR__, "fixtures", "controlled_restart_listener.jl"))
using .ControlledRestartListener
include(joinpath(@__DIR__, "conductor_process_test_support.jl"))
using .LocalConductorTestSupport

function run_bulk_cli(args, dir)
    output, errors = joinpath(dir, "bulk-cli.stdout"), joinpath(dir, "bulk-cli.stderr")
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__, "..", "scripts", "restart_conductor_servers.jl")) $args`
    process = run(pipeline(ignorestatus(command); stdout=output, stderr=errors))
    @test isempty(read(errors, String))
    return process.exitcode, read(output, String)
end

@testset "Bulk CLI full success and same-ID recovery" begin
    listeners = [start_restart_listener() for _ in 1:2]
    mktempdir() do dir
        conductor = start_local_conductor([(ip="127.0.0.1", port=node.port, name="node$index") for (index, node) in enumerate(listeners)], dir)
        try
            id = string(uuid4())
            args = ["127.0.0.1", string(conductor.port), "--operation-id", id]
            code, output = run_bulk_cli(args, dir)
            @test code == 0
            @test occursin("total_nodes=2 success_nodes=2 failed_nodes=0", output)
            @test occursin("operation_id=$id", output)
            @test all(node.restart_count == 1 for node in listeners)
            code, output = run_bulk_cli(vcat(args, ["--status"]), dir)
            @test code == 0
            @test all(node.restart_count == 1 for node in listeners)
            @test start_conductor_executor_restart("127.0.0.1"; conductor_port=conductor.port, operation_id=id).state == :complete
            @test all(node.restart_count == 1 for node in listeners)
            @test run_bulk_cli(["127.0.0.1", string(conductor.port), "--status", "--operation-id", string(uuid4())], dir)[1] == 3
            @test run_bulk_cli(["127.0.0.1", string(conductor.port), "--status"], dir)[1] == 64
        finally
            stop_local_conductor(conductor)
        end
    end
    foreach(stop_restart_listener!, listeners)
    @test all(isempty(node.connections) && isempty(node.errors) for node in listeners)
end

@testset "Bulk partial failure and client disconnect" begin
    good, busy = start_restart_listener(), start_restart_listener(mode=:busy)
    mktempdir() do dir
        conductor = start_local_conductor([(ip="127.0.0.1", port=good.port, name="good"), (ip="127.0.0.1", port=busy.port, name="busy")], dir)
        try
            code, output = run_bulk_cli(["127.0.0.1", string(conductor.port)], dir)
            @test code == 2
            @test occursin("success_nodes=1 failed_nodes=1", output)
            @test occursin("node=busy", output)
        finally
            stop_local_conductor(conductor)
        end
    end
    foreach(stop_restart_listener!, [good, busy])
    held = start_restart_listener(mode=:held)
    mktempdir() do dir
        conductor = start_local_conductor([(ip="127.0.0.1", port=held.port, name="held")], dir)
        id = string(uuid4())
        try
            socket = connect(ip"127.0.0.1", conductor.port)
            println(socket, add_checksum("RESTART_ALL|1|$id"))
            close(socket) # Operation must outlive this request connection.
            @test timedwait(() -> held.restart_count == 1, 5; pollint=0.01) == :ok
            @test query_conductor_executor_restart("127.0.0.1"; conductor_port=conductor.port, operation_id=id).state == :running
            code, output = run_bulk_cli(["127.0.0.1", string(conductor.port), "--operation-id", id, "--status"], dir)
            @test code == 4
            @test occursin("state=running", output)
            @test start_conductor_executor_restart("127.0.0.1"; conductor_port=conductor.port).state == :busy
            reply = local_conductor_request(conductor, "SUBMIT|127.0.0.1|1|source:Module:run")
            @test verify_checksum(reply)[2] == "ERROR|BUSY|MAINTENANCE"
            @test verify_checksum(local_conductor_request(conductor, "CACHE_CLEAR_ALL"))[2] == "ERROR|BUSY|MAINTENANCE"
            put!(held.release, nothing)
            result = wait_conductor_executor_restart("127.0.0.1"; conductor_port=conductor.port, operation_id=id, timeout=10)
            @test result.summary.overall_success
            @test held.restart_count == 1
            @test query_conductor_executor_restart("127.0.0.1"; conductor_port=conductor.port, operation_id=id).state == :complete
        finally
            put!(held.release, nothing)
            stop_local_conductor(conductor)
        end
    end
    stop_restart_listener!(held)
    @test isempty(held.errors)
end

@testset "Empty target CLI is not success" begin
    mktempdir() do dir
        conductor = start_local_conductor(NamedTuple[], dir)
        try
            code, output = run_bulk_cli(["127.0.0.1", string(conductor.port)], dir)
            @test code == 2
            @test occursin("total_nodes=0 success_nodes=0 failed_nodes=0 overall_success=false", output)
        finally
            stop_local_conductor(conductor)
        end
    end
end
