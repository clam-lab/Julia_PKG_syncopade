module ControlledRestartListener
using Sockets, UUIDs
export start_restart_listener, stop_restart_listener!, finish_delayed_restart!, runtime_fields

mutable struct RestartListener
    socket::Sockets.TCPServer
    port::Int
    listener_id::String
    server_id::String
    server_pid::Int
    state::Symbol
    mode::Symbol
    restart_count::Int
    entered::Channel{Nothing}
    release::Channel{Nothing}
    connections::Dict{TCPSocket,Task}
    accept_task::Union{Nothing,Task}
    errors::Vector{Any}
end

function wire(fields)
    payload = join([replace(string(field), "%" => "%25", "|" => "%7C", "\n" => "%0A", "\r" => "%0D") for field in fields], '|')
    check = foldl(⊻, codeunits(payload); init=UInt8(0))
    return payload * "|" * lowercase(string(check; base=16, pad=2))
end

runtime_fields(listener) = [listener.listener_id, listener.server_id, string(listener.state), string(getpid()),
    string(listener.server_pid), "fixture-julia", "fixture-syncopade", string(listener.state in (:idle, :busy))]

function finish_delayed_restart!(listener)
    listener.server_id = string(uuid4())
    listener.server_pid += 1
    listener.state = :idle
end

function handle_request!(listener, socket)
    row = readline(socket)
    fields = split(row, '|')
    if fields[1] == "STATUS"
        println(socket, "STATUS|" * (listener.state == :idle ? "idle" : "busy"))
    elseif listener.mode == :unsupported
        println(socket, wire(["ERROR", "UNKNOWN_COMMAND"]))
    elseif fields[1] == "RUNTIME"
        println(socket, wire(vcat(["RUNTIME", "1"], runtime_fields(listener))))
    elseif fields[1] == "RESTART"
        listener.restart_count += 1
        put!(listener.entered, nothing)
        old_listener, old_server = String(fields[3]), String(fields[4])
        status = "success"
        if (old_listener, old_server) != (listener.listener_id, listener.server_id)
            status = "id_mismatch"
        elseif listener.mode == :busy
            listener.state = :busy
            status = "busy"
        elseif listener.mode == :id_mismatch
            finish_delayed_restart!(listener)
            status = "id_mismatch"
        elseif listener.mode == :startup_failed
            finish_delayed_restart!(listener)
            listener.state = :unavailable
            status = "startup_failed"
        elseif listener.mode == :timeout
            read(socket)  # Wait until the bounded client closes; retain the old idle ID.
            return
        else
            if listener.mode == :held
                listener.state = :restarting
                take!(listener.release)
            end
            finish_delayed_restart!(listener)
            listener.mode == :drop && return
        end
        println(socket, wire(vcat(["RESTART", "1", status, old_listener, old_server], runtime_fields(listener), ["fixture reason|newline\n"])))
    else
        println(socket, wire(["ERROR", "UNKNOWN_COMMAND"]))
    end
end

function start_restart_listener(; mode=:success)
    socket = listen(ip"127.0.0.1", 0)
    listener = RestartListener(socket, getsockname(socket)[2], string(uuid4()), string(uuid4()), 1000, :idle,
        mode, 0, Channel{Nothing}(32), Channel{Nothing}(32), Dict{TCPSocket,Task}(), nothing, Any[])
    listener.accept_task = @async while isopen(socket)
        peer = try
            accept(socket)
        catch
            isopen(socket) && rethrow()
            break
        end
        listener.connections[peer] = @async try
            handle_request!(listener, peer)
        catch error
            error isa Base.IOError || error isa EOFError || push!(listener.errors, error)
        finally
            close(peer)
            delete!(listener.connections, peer)
        end
    end
    return listener
end

function stop_restart_listener!(listener)
    close(listener.socket)
    wait(listener.accept_task)
    pending = collect(listener.connections)
    for (socket, _) in pending
        close(socket)
        put!(listener.release, nothing)
    end
    for (_, task) in pending
        wait(task)
    end
    return nothing
end
end
