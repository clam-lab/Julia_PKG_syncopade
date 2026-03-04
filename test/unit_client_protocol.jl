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
end
