using Test, UUIDs
include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

@testset "Server management protocol validation" begin
    listener_id, old_id, new_id = [string(uuid4()) for _ in 1:3]
    fields = [listener_id, new_id, "idle", "100", "101", "1.12.3", "0.1.4", "true"]
    runtime_wire(values) = add_checksum(join(vcat(["RUNTIME", "1"], values), '|'))
    restart_wire(values, status="success") = add_checksum(join(vcat(["RESTART", "1", status, listener_id, old_id], values, ["reason%7Ca%0Ab%25"]), '|'))
    info = parse_server_runtime_response(runtime_wire(fields))
    @test info.listener_id == listener_id
    @test info.server_id == new_id
    @test info.ready
    result = parse_server_restart_response(restart_wire(fields), listener_id, old_id)
    @test result.status == :success
    @test result.reason == "reason|a\nb%"
    @test result.request_sent
    @test decode_management_field("%257C") == "%7C"
    @test_throws ServerManagementProtocolError decode_management_field("%ZZ")
    @test_throws ServerManagementProtocolError parse_server_runtime_response("STATUS|idle")
    @test_throws ServerManagementProtocolError parse_server_runtime_response(add_checksum("RUNTIME|2"))
    @test_throws ServerManagementProtocolError parse_server_runtime_response(runtime_wire(fields[1:7]))
    for (index, value) in [(1, ""), (2, "bad-id"), (3, "unknown"), (4, "0"), (5, "-1"), (5, "0"), (6, ""), (8, "maybe")]
        bad = copy(fields)
        bad[index] = value
        @test_throws ServerManagementProtocolError parse_server_runtime_response(runtime_wire(bad))
    end
    same_id = copy(fields)
    same_id[2] = old_id
    @test_throws ServerManagementProtocolError parse_server_restart_response(restart_wire(same_id), listener_id, old_id)
    other_listener = copy(fields)
    other_listener[1] = string(uuid4())
    @test_throws ServerManagementProtocolError parse_server_restart_response(restart_wire(other_listener), listener_id, old_id)
    @test_throws ServerManagementProtocolError parse_server_restart_response(restart_wire(fields), listener_id, string(uuid4()))
    @test_throws ServerManagementProtocolError parse_server_restart_response(restart_wire(fields, "mystery"), listener_id, old_id)
    for status in ("busy", "id_mismatch", "stop_failed", "startup_failed")
        @test parse_server_restart_response(restart_wire(fields, status), listener_id, old_id).status == Symbol(status)
    end
    @test_throws ArgumentError restart_server_executor("127.0.0.1"; server_port=1, expected_listener_id="", expected_server_id=old_id)
    @test_throws ArgumentError query_server_runtime("127.0.0.1"; server_port=0)
    @test_throws ArgumentError query_server_runtime("127.0.0.1"; server_port=1, timeout=0)
end
