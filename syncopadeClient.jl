using Sockets
using UUIDs

const DEFAULT_WIRED_LAN_PREFIX = "192.168.12."
const ACCEPTANCE_TIMEOUT_FIELD_PREFIX = "ACCEPTANCE_TIMEOUT_SECONDS="

function normalize_acceptance_timeout_seconds(value::Real)::Float64
    seconds = Float64(value)
    isfinite(seconds) && seconds > 0.0 || throw(ArgumentError(
        "acceptance_timeout_seconds must be finite and positive"
    ))
    return seconds
end

function preferred_local_ip(; prefix::AbstractString=get(ENV, "SYNCOPADE_WIRED_PREFIX", DEFAULT_WIRED_LAN_PREFIX))::IPAddr
    for ip in getipaddrs()
        if ip isa IPv4 && startswith(string(ip), String(prefix))
            return ip
        end
    end
    return getipaddr()
end

# syncopade job request and callback endpoint struct
"""
    SyncopadeClient

Client-side configuration for submitting a Syncopade job request and receiving the async callback.

# Fields
- `server_ip_addr::String`: Syncopade server IP address.
- `server_port::Int`: Syncopade server TCP port.
- `self_ip_addr::String`: Callback receiver (this machine) IP address.
- `self_port::Int`: Callback receiver TCP port.
- `file_name::String`: Remote-side file name (or identifier) that contains the target function.
- `module_name::String`: Remote-side module name.
- `function_name::String`: Remote-side function name.
- `args::Vector{String}`: Positional arguments encoded as strings.

# Notes
- This struct is purely a transport/config holder; validation is done by the server.
"""
struct SyncopadeClient
    server_ip_addr::String
    server_port::Int
    self_ip_addr::String
    self_port::Int
    file_name::String
    module_name::String
    function_name::String
    args::Vector{String}
end

abstract type WorkerStartReply end

struct WorkerStartAccepted <: WorkerStartReply
    job_id::String
end


struct WorkerStartBusy <: WorkerStartReply
    raw_response::String
end


struct SyncopadeWorkerBusyError <: Exception
    raw_response::String
end


struct SyncopadeWorkerProtocolError <: Exception
    raw_response::String
end


struct SyncopadeWorkerStartTimeoutError <: Exception
    timeout_seconds::Float64
end


abstract type ConductorTaskStatus end


struct KnownConductorTaskStatus <: ConductorTaskStatus
    task_id::String
    state::Symbol
    job_id::String
    terminal_kind::String
    reason::String
end


struct UnknownConductorTaskStatus <: ConductorTaskStatus
    task_id::String
end


function Base.showerror(io::IO, error_value::SyncopadeWorkerBusyError)
    print(io, "Unexpected response from server: ", error_value.raw_response)
end


function Base.showerror(io::IO, error_value::SyncopadeWorkerProtocolError)
    print(io, "Unexpected response from server: ", error_value.raw_response)
end


function Base.showerror(io::IO, error_value::SyncopadeWorkerStartTimeoutError)
    print(
        io,
        "dispatch timeout waiting worker start-ack > ",
        error_value.timeout_seconds,
        "s; worker acceptance outcome is unknown"
    )
end


function classify_worker_start_error(error_value)::Symbol
    if error_value isa SyncopadeWorkerBusyError
        return :busy
    elseif error_value isa SyncopadeWorkerProtocolError
        return :protocol_error
    elseif error_value isa SyncopadeWorkerStartTimeoutError
        return :outcome_unknown
    elseif error_value isa Base.IOError || error_value isa EOFError || error_value isa SystemError
        return :transport_error
    end
    return :unexpected_error
end

# checksum utilities
"""
    geneXORchecksum(s::String) -> UInt8

Compute a simple XOR checksum over the code units of `s`.

# Arguments
- `s`: Input string.

# Returns
- `UInt8`: XOR checksum value (0x00–0xFF).

# Notes
- Lightweight integrity check for transport errors.
- Not a cryptographic hash.
"""
function geneXORchecksum(s::String)
    c = UInt8(0)
    for b in codeunits(s)
        c ⊻= b
    end
    return c
end

"""
    checksum_hex(payload::String) -> String

Return the XOR checksum of `payload` as a 2-digit, lowercase hex string.

# Arguments
- `payload`: Message payload without the checksum suffix.

# Returns
- `String`: Two-character hex string (e.g., "0a").
"""
function checksum_hex(payload::String)::String
    c = geneXORchecksum(payload)
    return lowercase(string(c, base=16, pad=2))
end

"""
    add_checksum(payload::String) -> String

Append a checksum suffix to `payload` in the format `payload|cc`.

# Arguments
- `payload`: Message payload without the checksum suffix.

# Returns
- `String`: Payload with appended checksum field.
"""
function add_checksum(payload::String)::String
    return payload * "|" * checksum_hex(payload)
end

"""
    verify_checksum(msg::String) -> Tuple{Bool,String}

Verify the checksum of a `|`-separated message.

# Protocol
- The last field is treated as the checksum.
- Everything before it (including any intermediate `|`) is treated as the payload.

# Arguments
- `msg`: Full message string, expected to end with `|cc`.

# Returns
- `(ok, payload)` where:
  - `ok::Bool` indicates checksum match.
  - `payload::String` is the message without the trailing checksum field.

# Notes
- If the message does not have at least two fields, returns `(false, "")`.
"""
function verify_checksum(msg::String)::Tuple{Bool,String}
    parts = split(msg, '|')
    if length(parts) < 2
        return (false, "")
    end
    checksum_str = parts[end]
    payload = join(parts[1:end-1], '|')
    expected = checksum_hex(payload)
    return (checksum_str == expected, payload)
end


function parse_conductor_task_status_response(
    response::AbstractString
)::ConductorTaskStatus
    payload = String(chomp(response))
    parts = split(payload, '|'; keepempty=true)
    if length(parts) == 3 &&
       parts[1] == "TASK_STATUS" &&
       parts[2] == "UNKNOWN" &&
       !isempty(parts[3])
        return UnknownConductorTaskStatus(String(parts[3]))
    end

    if length(parts) >= 7 &&
       parts[1] == "TASK_STATUS" &&
       parts[2] == "KNOWN" &&
       !isempty(parts[3])
        state = Symbol(parts[4])
        state in (:queued, :reserved, :running, :dispatch_unknown, :terminal) ||
            throw(ArgumentError("unsupported conductor task state: $(parts[4])"))
        job_id = String(parts[5])
        terminal_kind = String(parts[6])
        reason = String(join(parts[7:end], "|"))

        if state == :running && isempty(job_id)
            throw(ArgumentError("running conductor task status requires job_id"))
        elseif state != :running && state != :terminal && !isempty(job_id)
            throw(ArgumentError("$state conductor task status must not contain job_id"))
        elseif state == :terminal && isempty(terminal_kind)
            throw(ArgumentError("terminal conductor task status requires terminal_kind"))
        elseif state != :terminal && (!isempty(terminal_kind) || !isempty(reason))
            throw(ArgumentError("non-terminal conductor task status contains terminal fields"))
        end

        return KnownConductorTaskStatus(
            String(parts[3]),
            state,
            job_id,
            terminal_kind,
            reason
        )
    end

    throw(ArgumentError("unexpected conductor task status response: $payload"))
end


function parse_worker_start_response(response::AbstractString)::WorkerStartReply
    raw_response = String(chomp(response))
    parts = split(raw_response, '|'; keepempty=true)
    if length(parts) == 3 &&
       parts[1] == "OK" &&
       parts[2] == "STARTED" &&
       !isempty(parts[3])
        return WorkerStartAccepted(String(parts[3]))
    elseif length(parts) == 2 && parts[1] == "ERROR" && parts[2] == "BUSY"
        return WorkerStartBusy(raw_response)
    end
    throw(SyncopadeWorkerProtocolError(raw_response))
end

"""
    syncopade_calc_request(pList::SyncopadeClient) -> String

Submit a Syncopade job request to the server and receive a `jobId`.

# Request Format (payload)
`self_ip_addr|self_port|file:module:func|arg1|arg2|...`

A checksum is appended automatically as `|cc`.

# Response Format
Expected single-line response:
- `OK|STARTED|jobId`

# Arguments
- `pList`: Client configuration and encoded arguments.

# Returns
- `String`: `jobId` assigned by the server.

# Throws
- `SyncopadeWorkerBusyError` if the worker explicitly rejects the request as busy.
- `SyncopadeWorkerProtocolError` if the response does not match the protocol.
- Transport exceptions from connect, write, or read operations.
"""
function syncopade_calc_request(pList::SyncopadeClient)::String
    sock = connect(pList.server_ip_addr, pList.server_port)
    try
        # フォーマットは self_ip_addr|self_port|file:module:func|arg1|arg2|...
        func_spec = string(pList.file_name, ":", pList.module_name, ":", pList.function_name)
        payload_parts = [pList.self_ip_addr, string(pList.self_port), func_spec]
        if !isempty(pList.args)
            append!(payload_parts, pList.args)
        end
        payload = join(payload_parts, "|")
        msg_with_checksum = add_checksum(payload)
        println(sock, msg_with_checksum)

        reply = parse_worker_start_response(readline(sock))
        if reply isa WorkerStartAccepted
            return reply.job_id
        end
        throw(SyncopadeWorkerBusyError(reply.raw_response))
    finally
        close(sock)
    end
end

"""
    syncopade_result_server(port::Int, handler::Function)

Start a result receiver server that listens forever and dispatches callbacks asynchronously.

# Behavior
- Binds to `preferred_local_ip()` and the specified `port`.
- For each incoming connection, reads one line, verifies checksum, and parses the payload.

# Expected Payload Formats
- `RESULT|jobId|OK|value`
- `RESULT|jobId|ERROR|errType|errMsg`

# Handler Signature
`handler(jobId::String, ok::Bool, payload::String)`
- When `ok == true`, `payload` is `value`.
- When `ok == false`, `payload` is `"errType|errMsg"`.

# Notes
- Runs with `@async`; this function returns immediately.
- Errors inside the accept/parse loop are intentionally swallowed to keep the server alive.
"""
function syncopade_result_server(port::Int, handler::Function)
    bind_ip = preferred_local_ip()
    server = listen(bind_ip, port)
    println("result server bind address: ", bind_ip, ":", port)
    @async while true
        sock = accept(server)
        @async begin
            try
                line = readline(sock)
                ok, payload = verify_checksum(line)
                if !ok
                    close(sock)
                    return
                end
                parts = split(payload, '|')
                # expected format:
                # RESULT|jobId|OK|value
                # or
                # RESULT|jobId|ERROR|errType|errMsg
                if length(parts) >= 4 && parts[1] == "RESULT"
                    jobId = parts[2]
                    status = parts[3]
                    if status == "OK"
                        value = join(parts[4:end], "|")
                        handler(jobId, true, value)
                    elseif status == "ERROR" && length(parts) >= 5
                        errType = parts[4]
                        errMsg = join(parts[5:end], "|")
                        handler(jobId, false, errType * "|" * errMsg)
                    end
                end
            catch e
                # ignore errors in handler
            end
            close(sock)
        end
    end
end

"""
    syncopade_result_server_once(port::Int, handler::Function)

Start a one-shot result receiver: accepts exactly one connection, handles one RESULT message, then shuts down.

# Expected Payload Formats
- `RESULT|jobId|OK|value`
- `RESULT|jobId|ERROR|errType|errMsg`

# Handler Signature
`handler(jobId::String, ok::Bool, payload::String)`

# Notes
- Runs with `@async`; this function returns immediately.
- After handling a single message, both the client socket and server socket are closed.
"""
function syncopade_result_server_once(port::Int, handler::Function)
    bind_ip = preferred_local_ip()
    server = listen(bind_ip, port)
    println("one-shot result server bind address: ", bind_ip, ":", port)
    @async begin
        try
            sock = accept(server)
            try
                line = readline(sock)
                ok, payload = verify_checksum(line)
                if ok
                    parts = split(payload, '|')
                    # expected format:
                    # RESULT|jobId|OK|value
                    # or
                    # RESULT|jobId|ERROR|errType|errMsg
                    if length(parts) >= 4 && parts[1] == "RESULT"
                        jobId = parts[2]
                        status = parts[3]
                        if status == "OK"
                            value = join(parts[4:end], "|")
                            handler(jobId, true, value)
                        elseif status == "ERROR" && length(parts) >= 5
                            errType = parts[4]
                            errMsg = join(parts[5:end], "|")
                            handler(jobId, false, errType * "|" * errMsg)
                        end
                    end
                end
            finally
                close(sock)
            end
        finally
            close(server)
        end
    end
end

"""
    query_server_status(server_ip::String, server_port::Int) -> String

Query a Syncopade server for its status.

# Protocol
- Sends `STATUS|cc` where `cc` is the XOR checksum of `STATUS`.
- Reads and returns a single-line response from the server.

# Returns
- `String`: Raw response line from the server.
"""
function query_server_status(server_ip::String, server_port::Int)
    sock = connect(server_ip, server_port)
    payload = "STATUS"
    msg = payload * "|" * checksum_hex(payload)
    println(sock, msg)
    resp = readline(sock)
    close(sock)
    return resp
end

function is_addr_in_use_error(e)::Bool
    msg = lowercase(sprint(showerror, e))
    return occursin("address already in use", msg) || occursin("eaddrinuse", msg)
end

function open_callback_listener(bind_ip::IPAddr, requested_port::Int)
    try
        server = listen(bind_ip, requested_port)
        _, bound_port_u = getsockname(server)
        return server, Int(bound_port_u), false
    catch e
        if requested_port > 0 && is_addr_in_use_error(e)
            server = listen(bind_ip, 0)
            _, bound_port_u = getsockname(server)
            return server, Int(bound_port_u), true
        end
        rethrow(e)
    end
end

#
# --- Conductor query helpers (ADD ONLY) ---
#
# Query Syncopade Conductor for available nodes
# Protocol:
#   Client -> Conductor : "LIST|cc"
#   Conductor -> Client : "NODES|ip:port|ip:port|...|cc"

"""
    query_conductor_nodes(conductor_ip::String; conductor_port::Int=9000) -> String

Query the Syncopade Conductor for available nodes.

# Protocol
Client -> Conductor:
- `LIST|cc`

Conductor -> Client:
- `NODES|ip:port|ip:port|...|cc`

# Returns
- `String`: Raw response line from the conductor.
"""
function query_conductor_nodes(conductor_ip::String; conductor_port::Int=9000)
    sock = connect(conductor_ip, conductor_port)
    println(sock, add_checksum("LIST"))
    resp = readline(sock)
    close(sock)
    ok, payload = verify_checksum(resp)
    if !ok
        error("Invalid checksum from conductor response: $resp")
    end
    return payload
end

"""
    query_conductor_nodes(conductor_ip::String, conductor_port::Int) -> String

Positional-argument overload of `query_conductor_nodes`.
"""
function query_conductor_nodes(conductor_ip::String, conductor_port::Int)
    return query_conductor_nodes(conductor_ip; conductor_port=conductor_port)
end

"""
    query_conductor_task_status(
        conductor_ip::String,
        task_id::String;
        conductor_port::Int=9000
    ) -> ConductorTaskStatus

Read one conductor task lifecycle snapshot without changing the task or node state.

# Returns
- `KnownConductorTaskStatus` for a task retained by the conductor.
- `UnknownConductorTaskStatus` when the conductor does not retain `task_id`.
"""
function query_conductor_task_status(
    conductor_ip::String,
    task_id::String;
    conductor_port::Int=9000
)::ConductorTaskStatus
    isempty(task_id) && throw(ArgumentError("task_id must not be empty"))
    sock = connect(conductor_ip, conductor_port)
    try
        println(sock, add_checksum("TASK_STATUS|$task_id"))
        response = readline(sock)
        ok, payload = verify_checksum(response)
        ok || throw(ArgumentError(
            "invalid checksum from conductor task status response: $response"
        ))
        return parse_conductor_task_status_response(payload)
    finally
        close(sock)
    end
end


function query_conductor_task_status(
    conductor_ip::String,
    conductor_port::Int,
    task_id::String
)::ConductorTaskStatus
    return query_conductor_task_status(
        conductor_ip,
        task_id;
        conductor_port=conductor_port
    )
end

"""
    parse_conductor_nodes(resp::String) -> Vector{Tuple{String,Int}}

Parse a conductor response string into a list of `(ip, port)` tuples.

# Input
- `resp`: Expected to be `NODES|ip:port|ip:port|...` or `NODES|...|cc`.

# Returns
- `Vector{Tuple{String,Int}}`: Parsed nodes; returns an empty vector on malformed input.

# Notes
- Any malformed `ip:port` entries are skipped.
"""
function parse_conductor_nodes(resp::String)
    # Accept both payload-only and checksum-attached response strings.
    ok, payload = verify_checksum(resp)
    raw = ok ? payload : resp

    parts = split(raw, '|')
    if isempty(parts) || parts[1] != "NODES"
        return Tuple{String,Int}[]
    end

    nodes = Tuple{String,Int}[]
    for p in parts[2:end]
        sp = split(p, ':')
        if length(sp) == 2
            ip = sp[1]
            port = try
                parse(Int, sp[2])
            catch
                continue
            end
            push!(nodes, (ip, port))
        end
    end
    return nodes
end


"""
    show_available_nodes(conductor_ip::String; conductor_port::Int=9000) -> Nothing

Fetch and print the list of available Syncopade nodes from the conductor.

# Output
Prints:
- `---- Available Syncopade Nodes ----`
- One `ip:port` per line, or `(none)` if the list is empty.

# Returns
- `nothing`
"""
function show_available_nodes(conductor_ip::String; conductor_port::Int=9000)
    resp = query_conductor_nodes(conductor_ip; conductor_port=conductor_port)
    nodes = parse_conductor_nodes(resp)

    println("---- Available Syncopade Nodes ----")
    if isempty(nodes)
        println(" (none)")
    else
        for (ip, port) in nodes
            println(" ", ip, ":", port)
        end
    end
    return nothing
end

"""
    show_available_nodes(conductor_ip::String, conductor_port::Int) -> Nothing

Positional-argument overload of `show_available_nodes`.
"""
function show_available_nodes(conductor_ip::String, conductor_port::Int)
    return show_available_nodes(conductor_ip; conductor_port=conductor_port)
end

"""
    clear_conductor_node_caches(conductor_ip::String; conductor_port::Int=9000) -> NamedTuple

Send `CACHE_CLEAR_ALL` command to the Syncopade Conductor and request cache clear on all configured nodes.

# Protocol
Client -> Conductor:
- `CACHE_CLEAR_ALL|cc`

Conductor -> Client payload:
- `OK|CACHE_CLEAR_ALL|total_nodes|success_nodes|failed_nodes|cleared_functions`

# Returns
- NamedTuple:
  - `total_nodes::Int`
  - `success_nodes::Int`
  - `failed_nodes::Int`
  - `cleared_functions::Int`
"""
function clear_conductor_node_caches(conductor_ip::String; conductor_port::Int=9000)
    sock = connect(conductor_ip, conductor_port)
    try
        println(sock, add_checksum("CACHE_CLEAR_ALL"))
        resp = readline(sock)
        ok, payload = verify_checksum(resp)
        if !ok
            error("Invalid checksum from conductor response: $resp")
        end

        parts = split(payload, '|')
        if length(parts) == 6 && parts[1] == "OK" && parts[2] == "CACHE_CLEAR_ALL"
            total_nodes = parse(Int, parts[3])
            success_nodes = parse(Int, parts[4])
            failed_nodes = parse(Int, parts[5])
            cleared_functions = parse(Int, parts[6])
            return (
                total_nodes=max(total_nodes, 0),
                success_nodes=max(success_nodes, 0),
                failed_nodes=max(failed_nodes, 0),
                cleared_functions=max(cleared_functions, 0)
            )
        end

        error("Unexpected response from conductor: $payload")
    finally
        close(sock)
    end
end

"""
    clear_conductor_node_caches(conductor_ip::String, conductor_port::Int) -> NamedTuple

Positional-argument overload of `clear_conductor_node_caches`.
"""
function clear_conductor_node_caches(conductor_ip::String, conductor_port::Int)
    return clear_conductor_node_caches(conductor_ip; conductor_port=conductor_port)
end

"""
    submit_conductor_task(
        conductor_ip::String;
        conductor_port::Int=9000,
        coordinator_ip::String,
        coordinator_port::Union{Nothing,Int}=nothing,
        source::String,
        module_name::String,
        function_name::String,
        args::Vector{String}=String[],
        acceptance_timeout_seconds::Union{Nothing,Real}=nothing
    ) -> String

Submit one task to Syncopade Conductor and receive a conductor `task_id`.

# Protocol
Client -> Conductor payload:
- `SUBMIT|ACCEPTANCE_TIMEOUT_SECONDS=s(optional)|coord_ip|coord_port(optional)|source:module:function|arg1|arg2|...`

The payload is sent as `payload|cc` with XOR checksum.

Conductor -> Client payload:
- `OK|QUEUED|task_id`

# Returns
- `String`: Queued conductor task id.
"""
function submit_conductor_task(
    conductor_ip::String;
    conductor_port::Int=9000,
    coordinator_ip::String,
    coordinator_port::Union{Nothing,Int}=nothing,
    source::String,
    module_name::String,
    function_name::String,
    args::Vector{String}=String[],
    acceptance_timeout_seconds::Union{Nothing,Real}=nothing
)
    func_spec = string(source, ":", module_name, ":", function_name)
    payload_parts = String["SUBMIT"]
    if acceptance_timeout_seconds !== nothing
        timeout_value = normalize_acceptance_timeout_seconds(acceptance_timeout_seconds)
        push!(
            payload_parts,
            ACCEPTANCE_TIMEOUT_FIELD_PREFIX * string(timeout_value)
        )
    end
    push!(payload_parts, coordinator_ip)
    if coordinator_port !== nothing
        push!(payload_parts, string(coordinator_port))
    end
    push!(payload_parts, func_spec)
    if !isempty(args)
        append!(payload_parts, args)
    end

    payload = join(payload_parts, "|")
    msg = add_checksum(payload)

    sock = connect(conductor_ip, conductor_port)
    println(sock, msg)
    resp = readline(sock)
    close(sock)

    ok, resp_payload = verify_checksum(resp)
    if !ok
        error("Invalid checksum from conductor response: $resp")
    end

    parts = split(resp_payload, '|')
    if length(parts) == 3 && parts[1] == "OK" && parts[2] == "QUEUED"
        return parts[3]
    else
        error("Unexpected response from conductor: $resp_payload")
    end
end

"""
    submit_conductor_task_and_wait(
        conductor_ip::String;
        conductor_port::Int=9000,
        coordinator_ip::String=string(preferred_local_ip()),
        coordinator_port::Int,
        source::String,
        module_name::String,
        function_name::String,
        args::Vector{String}=String[],
        acceptance_timeout_seconds::Union{Nothing,Real}=nothing,
        timeout::Float64=60.0
    ) -> NamedTuple

Submit one task to the conductor and wait for exactly one callback result on `coordinator_port`.

# Returns
- `(task_id, job_id, ok, payload)`:
  - `task_id::String`: Conductor queue task id
  - `job_id::String`: Worker job id from RESULT callback
  - `ok::Bool`: `true` for RESULT OK, `false` for RESULT ERROR
  - `payload::String`: Result value (OK) or `errType|errMsg` (ERROR)

# Notes
- The callback listener is started before SUBMIT to avoid race conditions.
- Throws `error(...)` on timeout, checksum error, or malformed callback payload.
"""
function submit_conductor_task_and_wait(
    conductor_ip::String;
    conductor_port::Int=9000,
    coordinator_ip::String=string(preferred_local_ip()),
    coordinator_port::Int,
    source::String,
    module_name::String,
    function_name::String,
    args::Vector{String}=String[],
    acceptance_timeout_seconds::Union{Nothing,Real}=nothing,
    timeout::Float64=60.0
)
    bind_ip = preferred_local_ip()
    server = nothing
    bound_port = coordinator_port
    sock = nothing

    try
        server, bound_port, fallback_used = open_callback_listener(bind_ip, coordinator_port)
        if fallback_used
            println("callback port ", coordinator_port, " is in use; fallback to ", bound_port)
        end

        accept_task = @async accept(server)

        task_id = submit_conductor_task(
            conductor_ip;
            conductor_port=conductor_port,
            coordinator_ip=coordinator_ip,
            coordinator_port=bound_port,
            source=source,
            module_name=module_name,
            function_name=function_name,
            args=args,
            acceptance_timeout_seconds=acceptance_timeout_seconds
        )

        w_accept = Base.timedwait(() -> istaskdone(accept_task), timeout; pollint=0.01)
        if w_accept === :timed_out
            error("timeout waiting callback connection on $(string(bind_ip)):$(bound_port)")
        end
        sock = fetch(accept_task)

        line_task = @async readline(sock)
        w_line = Base.timedwait(() -> istaskdone(line_task), timeout; pollint=0.01)
        if w_line === :timed_out
            error("timeout waiting callback payload on $(string(bind_ip)):$(bound_port)")
        end
        line = fetch(line_task)

        chk_ok, payload = verify_checksum(line)
        if !chk_ok
            error("Invalid checksum in callback: $line")
        end

        parts = split(payload, '|')
        if length(parts) >= 4 && parts[1] == "RESULT"
            job_id = parts[2]
            status = parts[3]
            if status == "OK"
                value = join(parts[4:end], "|")
                return (task_id=task_id, job_id=job_id, ok=true, payload=value)
            elseif status == "ERROR" && length(parts) >= 5
                errType = parts[4]
                errMsg = join(parts[5:end], "|")
                return (task_id=task_id, job_id=job_id, ok=false, payload=errType * "|" * errMsg)
            end
        end

        error("Unexpected callback payload: $payload")
    finally
        if sock !== nothing
            try
                close(sock)
            catch
            end
        end
        if server !== nothing
            try
                close(server)
            catch
            end
        end
    end
end
