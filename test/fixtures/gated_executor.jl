# Use the real execution loop; only hold its STOPPED frame at a test gate.
include(joinpath(@__DIR__, "..", "..", "syncopadeExecutor.jl"))
struct StopGateIO <: IO
    socket::TCPSocket
end
Base.read(io::StopGateIO, count::Integer) = read(io.socket, count)
Base.flush(io::StopGateIO) = flush(io.socket)
function Base.write(io::StopGateIO, bytes::Vector{UInt8})
    message = read_executor_message(IOBuffer(bytes))
    if message.kind == "STOPPED"
        write(ENV["SYNCOPADE_STOP_ENTERED"], string(getpid()))
        while !isfile(ENV["SYNCOPADE_STOP_RELEASE"])
            sleep(0.01)
        end
    end
    return write(io.socket, bytes)
end
socket = connect(ip"127.0.0.1", parse(Int, ARGS[1]))
try
    run_executor_loop(StopGateIO(socket), ARGS[2], ARGS[3])
finally
    close(socket)
end
