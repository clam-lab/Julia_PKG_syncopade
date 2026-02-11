using Test

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

@testset "Client Protocol" begin
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
end
