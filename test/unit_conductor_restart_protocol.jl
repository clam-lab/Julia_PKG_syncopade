using Test, UUIDs
include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

@testset "Bulk restart protocol strict totals and identities" begin
    id, listener, old, new = [string(uuid4()) for _ in 1:4]
    info = [listener, new, "idle", "1", "2", "Julia", "Syncopade", "true"]
    node = vcat(["127.0.0.1", "8001", "name|改行\n", "success", listener, old, "true", "true"], info, ["reason%"])
    function complete(nodes; total=length(nodes), success=length(nodes), failed=total-success, overall=total>0 && success==total)
        management_response(vcat(["RESTART_ALL", "1", id, "complete", string(total), string(success), string(failed), string(overall)], nodes...))
    end
    parsed = parse_conductor_restart_response(complete([node]), id)
    @test parsed.summary.overall_success
    @test parsed.nodes[1].name == "name|改行\n"
    @test parsed.nodes[1].result.reason == "reason%"
    @test parsed.nodes[1].result.runtime.server_id == new
    @test !parse_conductor_restart_response(complete(Vector{String}[]), id).summary.overall_success
    @test_throws ServerManagementProtocolError parse_conductor_restart_response(complete(Vector{String}[]; overall=true), id)
    @test_throws ServerManagementProtocolError parse_conductor_restart_response(complete([node]; success=0, failed=1), id)
    @test_throws ServerManagementProtocolError parse_conductor_restart_response(complete([node]; failed=1), id)
    @test_throws ServerManagementProtocolError parse_conductor_restart_response(complete([node]; total=2, success=2), id)
    @test_throws ServerManagementProtocolError parse_conductor_restart_response(complete([node, node]), id)
    @test_throws ServerManagementProtocolError parse_conductor_restart_response(complete([node]), string(uuid4()))
    for (index, value) in [(1, "bad-ip"), (2, "0"), (4, "made-up"), (5, ""), (6, ""), (7, "false"), (8, "false"), (10, old), (16, "false")]
        invalid = copy(node)
        invalid[index] = value
        @test_throws ServerManagementProtocolError parse_conductor_restart_response(complete([invalid]), id)
    end
    transport = vcat(["127.0.0.1", "8002", "down", "transport_error", "", "", "false", "false"], fill("", 8), ["refused"])
    mixed = parse_conductor_restart_response(complete([node, transport]; success=1, failed=1), id)
    @test !mixed.summary.overall_success
    @test mixed.summary.failed_nodes == 1
    @test mixed.nodes[2].result.runtime === nothing
    for state in ("busy", "unknown")
        @test parse_conductor_restart_response(management_response(["RESTART_ALL", "1", id, state]), id).state == Symbol(state)
    end
    running = parse_conductor_restart_response(management_response(["RESTART_ALL", "1", id, "running", "2", "1"]), id)
    @test running.summary === nothing
    @test running.completed_count == 1
    @test_throws ServerManagementProtocolError parse_conductor_restart_response(management_response(["RESTART_ALL", "1", id, "running", "0", "1"]), id)
    @test_throws ArgumentError start_conductor_executor_restart("127.0.0.1"; conductor_port=1, operation_id="")
    @test_throws ArgumentError wait_conductor_executor_restart("127.0.0.1"; conductor_port=1, operation_id=id, timeout=0)
end
