using Test, UUIDs, Sockets
include(joinpath(@__DIR__, "..", "syncopadeExecutorProtocol.jl"))
using .ExecutorProtocol
include(joinpath(@__DIR__, "..", "syncopadeServerRuntime.jl"))

function wire_bytes(message)
    io = IOBuffer()
    write_executor_message(io, message)
    return take!(io)
end

@testset "Executor wire framing and identity" begin
    listener_id, server_id, request_id = [string(uuid4()) for _ in 1:3]
    messages = [
        ExecutorMessage("READY", listener_id, server_id, "", [string(getpid()), string(VERSION), "0.1.4"]),
        ExecutorMessage("EXECUTE", listener_id, server_id, request_id, ["file", "Module", "run", "", "a|b\n先生🌸"]),
        ExecutorMessage("RESULT", listener_id, server_id, request_id, ["OK", "a|b\n先生🌸"]),
        ExecutorMessage("RESULT", listener_id, server_id, request_id, ["ERROR", "RUNTIME_ERROR", ""]),
        ExecutorMessage("CLEAR", listener_id, server_id, request_id, String[]),
        ExecutorMessage("CLEARED", listener_id, server_id, request_id, ["12"]),
        ExecutorMessage("STOP", listener_id, server_id, request_id, String[]),
        ExecutorMessage("STOPPED", listener_id, server_id, request_id, String[]),
    ]
    for message in messages
        decoded = read_executor_message(IOBuffer(wire_bytes(message)))
        @test decoded.data == message.data
        @test expect_executor_message(decoded, message.kind, listener_id, server_id, message.request_id) === decoded
    end
    message = messages[2]
    @test_throws ArgumentError expect_executor_message(message, "RESULT", listener_id, server_id, request_id)
    @test_throws ArgumentError expect_executor_message(message, "EXECUTE", string(uuid4()), server_id, request_id)
    @test_throws ArgumentError expect_executor_message(message, "EXECUTE", listener_id, string(uuid4()), request_id)
    @test_throws ArgumentError expect_executor_message(message, "EXECUTE", listener_id, server_id, string(uuid4()))
    for (kind, data) in [("UNKNOWN", String[]), ("CLEARED", ["-1"]), ("CLEAR", ["extra"]), ("RESULT", ["OK"]), ("EXECUTE", ["", "m", "f"])]
        @test_throws ArgumentError wire_bytes(ExecutorMessage(kind, listener_id, server_id, request_id, data))
    end
    @test_throws ArgumentError wire_bytes(ExecutorMessage("CLEAR", "", server_id, request_id, String[]))
    @test_throws ArgumentError wire_bytes(ExecutorMessage("CLEAR", listener_id, server_id, "", String[]))
    @test_throws ArgumentError wire_bytes(ExecutorMessage("RESULT", listener_id, server_id, request_id, ["OK", "x"^ExecutorProtocol.MAX_FRAME_BYTES]))
    @test_throws ArgumentError wire_bytes(ExecutorMessage("EXECUTE", listener_id, server_id, request_id, fill("x", 4096)))
    bytes = wire_bytes(message)
    for stop in (0, 1, 3, 4, 5, length(bytes) - 1)
        @test_throws EOFError read_executor_message(IOBuffer(bytes[1:stop]))
    end
    @test_throws ArgumentError read_executor_message(IOBuffer(UInt8[0xff, 0xff, 0xff, 0xff]))
    @test_throws ArgumentError read_executor_message(IOBuffer(UInt8[0, 0, 0, 0]))
    invalid_count = copy(bytes)
    invalid_count[5:8] .= 0xff
    @test_throws ArgumentError read_executor_message(IOBuffer(invalid_count))
    invalid_size = copy(bytes)
    invalid_size[9:12] .= 0xff
    @test_throws ArgumentError read_executor_message(IOBuffer(invalid_size))
    invalid_version = copy(bytes)
    invalid_version[13] = UInt8('2')
    @test_throws ArgumentError read_executor_message(IOBuffer(invalid_version))
    invalid_utf8 = copy(bytes)
    invalid_utf8[13] = 0xff
    @test_throws ArgumentError read_executor_message(IOBuffer(invalid_utf8))
    runtime = ServerRuntime()
    before = runtime_snapshot(runtime)
    @test_throws ArgumentError expect_executor_message(messages[1], "READY", before.listener_id, before.server_id, "")
    @test runtime_snapshot(runtime) == before

    # Three writes arrive separately; read must assemble the whole frame.
    listener = listen(ip"127.0.0.1", 0)
    client = connect(ip"127.0.0.1", getsockname(listener)[2])
    peer = accept(listener)
    try
        writer = @async begin
            for chunk in (bytes[1:2], bytes[3:17], bytes[18:end])
                write(client, chunk)
                flush(client)
                yield()
            end
        end
        @test read_executor_message(peer).data == message.data
        wait(writer)
        close(client)
        @test_throws EOFError read_executor_message(peer)
    finally
        close(client)
        close(peer)
        close(listener)
    end
end
