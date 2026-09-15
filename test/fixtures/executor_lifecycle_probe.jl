using Sockets, UUIDs
include(joinpath(@__DIR__, "..", "..", "syncopadeExecutorProtocol.jl"))
using .ExecutorProtocol

mode = ENV["SYNCOPADE_LIFECYCLE_FIXTURE"]
mode == "exit_before" && exit(7)
mode == "throw_before" && error("deliberate startup fixture error")
socket = connect(ip"127.0.0.1", parse(Int, ARGS[1]))
if mode == "no_ready"
    # Consume until parent disconnects; do not send READY.
    read(socket)
elseif mode == "bad_id"
    write_executor_message(socket, ExecutorMessage("READY", ARGS[2], string(uuid4()), "",
        [string(getpid()), string(VERSION), "fixture"]))
    read(socket)
elseif mode in ("ignore_stop", "ignore_clear")
    write_executor_message(socket, ExecutorMessage("READY", ARGS[2], ARGS[3], "",
        [string(getpid()), string(VERSION), "fixture"]))
    read_executor_message(socket)
    read(socket)
elseif mode == "delayed_stop"
    write_executor_message(socket, ExecutorMessage("READY", ARGS[2], ARGS[3], "",
        [string(getpid()), string(VERSION), "fixture"]))
    message = read_executor_message(socket)
    message.kind == "STOP" || error("expected STOP")
    write(ENV["SYNCOPADE_STOP_ENTERED"], "entered")
    while !isfile(ENV["SYNCOPADE_STOP_RELEASE"])
        sleep(0.01)
    end
    write_executor_message(socket, ExecutorMessage("STOPPED", ARGS[2], ARGS[3], message.request_id, String[]))
else
    error("unknown lifecycle fixture mode")
end
close(socket)
