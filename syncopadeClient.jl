using Sockets
using UUIDs

"""Identity and readiness of a listener and its current executor; not a package revision guarantee."""
struct ServerRuntimeInfo
    listener_id::String
    server_id::String
    state::Symbol
    listener_pid::Int
    server_pid::Int
    julia_version::String
    syncopade_version::String
    ready::Bool
end

"""Explicit restart outcome. `unknown` must be reconciled by querying, never blindly retried."""
struct ServerRestartResult
    status::Symbol
    old_listener_id::String
    old_server_id::String
    runtime::Union{Nothing,ServerRuntimeInfo}
    reason::String
    request_sent::Bool
end

struct ServerManagementProtocolError <: Exception
    message::String
end
Base.showerror(io::IO, error::ServerManagementProtocolError) = print(io, error.message)

struct ServerManagementTransportError <: Exception
    message::String
    request_sent::Bool
end
Base.showerror(io::IO, error::ServerManagementTransportError) = print(io, error.message)

function valid_management_uuid(value::AbstractString)::Bool
    try
        return string(UUID(value)) == value
    catch
        return false
    end
end

function decode_management_field(value::AbstractString)::String
    # Only these four characters are escaped by protocol version 1.
    occursin(r"%(?!25|7C|0A|0D)", value) && throw(ServerManagementProtocolError("invalid management escape"))
    return replace(String(value), "%7C" => "|", "%0A" => "\n", "%0D" => "\r", "%25" => "%")
end

encode_management_field(value::AbstractString) = replace(String(value), "%" => "%25", "|" => "%7C", "\n" => "%0A", "\r" => "%0D")
management_response(fields::Vector{String}) = add_checksum(join(encode_management_field.(fields), '|'))
management_runtime_fields(info::ServerRuntimeInfo) = [info.listener_id, info.server_id, string(info.state),
    string(info.listener_pid), string(info.server_pid), info.julia_version, info.syncopade_version, string(info.ready)]
management_runtime_fields(::Nothing) = fill("", 8)

function parse_management_fields(row::String)
    valid, payload = verify_checksum(row)
    valid || throw(ServerManagementProtocolError("invalid management checksum or unsupported server"))
    return decode_management_field.(split(payload, '|'))
end

function parse_runtime_fields(fields::Vector{String})::ServerRuntimeInfo
    length(fields) == 8 || throw(ServerManagementProtocolError("invalid runtime field count"))
    all(valid_management_uuid, fields[1:2]) || throw(ServerManagementProtocolError("invalid runtime identity"))
    state = Symbol(fields[3])
    state in (:starting, :idle, :busy, :restarting, :unavailable, :stopping) || throw(ServerManagementProtocolError("unknown runtime state"))
    listener_pid, server_pid = tryparse.(Int, fields[4:5])
    listener_pid !== nothing && listener_pid > 0 && server_pid !== nothing && server_pid >= 0 ||
        throw(ServerManagementProtocolError("invalid runtime PID"))
    fields[8] in ("true", "false") || throw(ServerManagementProtocolError("invalid runtime ready flag"))
    ready = fields[8] == "true"
    if ready
        state in (:idle, :busy) && server_pid > 0 && !isempty(fields[6]) && !isempty(fields[7]) ||
            throw(ServerManagementProtocolError("inconsistent runtime readiness"))
    end
    return ServerRuntimeInfo(fields[1], fields[2], state, listener_pid, server_pid, fields[6], fields[7], ready)
end

function parse_server_runtime_response(row::String)::ServerRuntimeInfo
    fields = parse_management_fields(row)
    length(fields) == 10 && fields[1:2] == ["RUNTIME", "1"] || throw(ServerManagementProtocolError("unsupported runtime response"))
    return parse_runtime_fields(fields[3:end])
end

function parse_server_restart_response(row::String, expected_listener_id::String, expected_server_id::String)::ServerRestartResult
    fields = parse_management_fields(row)
    length(fields) == 14 && fields[1:2] == ["RESTART", "1"] || throw(ServerManagementProtocolError("unsupported restart response"))
    status = Symbol(fields[3])
    status in (:success, :busy, :id_mismatch, :stop_failed, :startup_failed) || throw(ServerManagementProtocolError("unknown restart status"))
    fields[4:5] == [expected_listener_id, expected_server_id] || throw(ServerManagementProtocolError("restart response request mismatch"))
    info = parse_runtime_fields(fields[6:13])
    if status == :success
        info.listener_id == expected_listener_id && info.server_id != expected_server_id && info.ready ||
            throw(ServerManagementProtocolError("restart success without confirmed replacement"))
    end
    return ServerRestartResult(status, fields[4], fields[5], info, fields[14], true)
end

function management_request(ip::AbstractString, port::Integer, payload::String; timeout::Real)
    0 < port <= 65535 || throw(ArgumentError("port must be in 1:65535"))
    isfinite(timeout) && timeout > 0 || throw(ArgumentError("timeout must be positive finite seconds"))
    address = parse(IPAddr, ip)
    socket = TCPSocket()
    sent = false
    expired = Ref(false)
    timer = Timer(Float64(timeout)) do _
        expired[] = true
        close(socket)
    end
    try
        connect(socket, address, port)
        # A partial write may already be visible remotely; never promise non-execution.
        sent = true
        println(socket, add_checksum(payload))
        row = readline(socket)
        isempty(row) && throw(EOFError())
        return row
    catch error
        message = expired[] ? "management request timed out" : sprint(showerror, error)
        throw(ServerManagementTransportError(message, sent))
    finally
        close(timer)
        close(socket)
    end
end

"""
    query_server_runtime(ip; server_port, timeout=5)

Read listener/executor boot IDs and readiness at an explicit endpoint. Never changes a server.
Throws `ServerManagementTransportError` or `ServerManagementProtocolError` on failure.
"""
function query_server_runtime(ip::AbstractString; server_port::Integer, timeout::Real=5.0)::ServerRuntimeInfo
    return parse_server_runtime_response(management_request(ip, server_port, "RUNTIME"; timeout))
end

"""
    restart_server_executor(ip; server_port, expected_listener_id, expected_server_id, timeout=60)

Request exactly one idle executor replacement using previously queried boot IDs.
`success` confirms replacement, `busy`/`id_mismatch` reject it, and `unknown` means a
request may have executed. Query runtime after an unknown outcome; do not auto-resend.
This does not deploy or validate application package versions.
"""
function restart_server_executor(ip::AbstractString; server_port::Integer,
    expected_listener_id::AbstractString, expected_server_id::AbstractString, timeout::Real=60.0)::ServerRestartResult
    listener_id, server_id = String(expected_listener_id), String(expected_server_id)
    valid_management_uuid(listener_id) && valid_management_uuid(server_id) || throw(ArgumentError("expected IDs must be canonical UUIDs"))
    row = try
        management_request(ip, server_port, "RESTART|1|$listener_id|$server_id"; timeout)
    catch error
        error isa ServerManagementTransportError || rethrow()
        return ServerRestartResult(error.request_sent ? :unknown : :transport_error, listener_id, server_id, nothing, error.message, error.request_sent)
    end
    try
        return parse_server_restart_response(row, listener_id, server_id)
    catch error
        error isa ServerManagementProtocolError || rethrow()
        return ServerRestartResult(:unknown, listener_id, server_id, nothing, error.message, true)
    end
end

struct ConductorRestartNodeResult
    ip::String
    port::Int
    name::String
    result::ServerRestartResult
end

"""Operation receipt. A summary exists only for a complete, fully validated result."""
struct ConductorRestartStatus
    operation_id::String
    state::Symbol
    target_count::Int
    completed_count::Int
    nodes::Vector{ConductorRestartNodeResult}
    summary::Union{Nothing,NamedTuple}
    reason::String
end

function management_nonnegative_int(value::String)
    parsed = tryparse(Int, value)
    parsed !== nothing && parsed >= 0 || throw(ServerManagementProtocolError("invalid management count"))
    return parsed
end

function parse_conductor_restart_response(row::String, operation_id::String)::ConductorRestartStatus
    fields = parse_management_fields(row)
    length(fields) >= 4 && fields[1:3] == ["RESTART_ALL", "1", operation_id] && valid_management_uuid(operation_id) ||
        throw(ServerManagementProtocolError("invalid restart operation header"))
    state = Symbol(fields[4])
    if state in (:busy, :unknown)
        length(fields) == 4 || throw(ServerManagementProtocolError("unexpected operation fields"))
        return ConductorRestartStatus(operation_id, state, 0, 0, ConductorRestartNodeResult[], nothing, "")
    elseif state == :running
        length(fields) == 6 || throw(ServerManagementProtocolError("invalid running operation fields"))
        total, completed = management_nonnegative_int.(fields[5:6])
        completed <= total || throw(ServerManagementProtocolError("invalid operation progress"))
        return ConductorRestartStatus(operation_id, state, total, completed, ConductorRestartNodeResult[], nothing, "")
    end
    state == :complete && length(fields) >= 8 || throw(ServerManagementProtocolError("unknown operation state"))
    total, successes, failures = management_nonnegative_int.(fields[5:7])
    # Check available fields first, avoiding integer overflow or huge allocations from untrusted counts.
    (length(fields) - 8) % 17 == 0 && total == (length(fields) - 8) ÷ 17 || throw(ServerManagementProtocolError("incomplete node result list"))
    successes <= total && failures == total - successes || throw(ServerManagementProtocolError("inconsistent result totals"))
    fields[8] in ("true", "false") || throw(ServerManagementProtocolError("invalid overall success flag"))
    nodes = ConductorRestartNodeResult[]
    seen = Set{Tuple{String,Int}}()
    for index in 0:(total - 1)
        entry = fields[(9 + 17index):(25 + 17index)]
        address = try
            string(parse(IPAddr, entry[1]))
        catch
            throw(ServerManagementProtocolError("invalid node IP"))
        end
        port = management_nonnegative_int(entry[2])
        0 < port <= 65535 || throw(ServerManagementProtocolError("invalid node port"))
        key = (address, port)
        key in seen && throw(ServerManagementProtocolError("duplicate node endpoint"))
        push!(seen, key)
        status = Symbol(entry[4])
        entry[7] in ("true", "false") && entry[8] in ("true", "false") || throw(ServerManagementProtocolError("invalid node flags"))
        sent, has_runtime = entry[7] == "true", entry[8] == "true"
        runtime = has_runtime ? parse_runtime_fields(entry[9:16]) : nothing
        !has_runtime && any(!isempty, entry[9:16]) && throw(ServerManagementProtocolError("unexpected runtime data"))
        result = if status in (:success, :busy, :id_mismatch, :stop_failed, :startup_failed)
            sent && has_runtime && all(valid_management_uuid, entry[5:6]) || throw(ServerManagementProtocolError("missing restart identity"))
            parse_server_restart_response(management_response(vcat(["RESTART", "1", entry[4], entry[5], entry[6]], entry[9:16], [entry[17]])), entry[5], entry[6])
        elseif status == :unknown
            sent && all(valid_management_uuid, entry[5:6]) || throw(ServerManagementProtocolError("unknown outcome without request identity"))
            ServerRestartResult(status, entry[5], entry[6], runtime, entry[17], sent)
        elseif status in (:unsupported, :transport_error)
            !sent && !has_runtime && all(isempty, entry[5:6]) || throw(ServerManagementProtocolError("invalid pre-request failure"))
            ServerRestartResult(status, "", "", nothing, entry[17], false)
        else
            throw(ServerManagementProtocolError("unknown node restart outcome"))
        end
        push!(nodes, ConductorRestartNodeResult(entry[1], port, entry[3], result))
    end
    count(node -> node.result.status == :success, nodes) == successes || throw(ServerManagementProtocolError("success count does not match node results"))
    overall = total > 0 && successes == total
    (fields[8] == "true") == overall || throw(ServerManagementProtocolError("incorrect overall success"))
    summary = (total_nodes=total, success_nodes=successes, failed_nodes=failures, overall_success=overall)
    return ConductorRestartStatus(operation_id, :complete, total, total, nodes, summary, "")
end

function unresolved_conductor_restart(operation_id::String, state::Symbol, reason::String)
    ConductorRestartStatus(operation_id, state, 0, 0, ConductorRestartNodeResult[], nothing, reason)
end

"""
    start_conductor_executor_restart(ip; conductor_port, operation_id=string(uuid4()), timeout=5)

Start one operation over all configured nodes. Keep the returned operation ID even if
the reply is `outcome_unknown`. Never starts a second operation to recover a lost reply.
"""
function start_conductor_executor_restart(ip::AbstractString; conductor_port::Integer,
    operation_id::AbstractString=string(uuid4()), timeout::Real=5.0)::ConductorRestartStatus
    id = String(operation_id)
    valid_management_uuid(id) || throw(ArgumentError("operation_id must be a canonical UUID"))
    row = try
        management_request(ip, conductor_port, "RESTART_ALL|1|$id"; timeout)
    catch error
        error isa ServerManagementTransportError || rethrow()
        return unresolved_conductor_restart(id, error.request_sent ? :outcome_unknown : :not_started, error.message)
    end
    try
        return parse_conductor_restart_response(row, id)
    catch error
        error isa ServerManagementProtocolError || rethrow()
        return unresolved_conductor_restart(id, :outcome_unknown, error.message)
    end
end

"""Query a recorded operation only. `unknown` after conductor restart is not permission to reissue it."""
function query_conductor_executor_restart(ip::AbstractString; conductor_port::Integer,
    operation_id::AbstractString, timeout::Real=5.0)::ConductorRestartStatus
    id = String(operation_id)
    valid_management_uuid(id) || throw(ArgumentError("operation_id must be a canonical UUID"))
    return parse_conductor_restart_response(management_request(ip, conductor_port, "RESTART_ALL_STATUS|1|$id"; timeout), id)
end

"""Wait by querying the same operation ID. Does not retry restart commands; timeout is not a computation limit."""
function wait_conductor_executor_restart(ip::AbstractString; conductor_port::Integer,
    operation_id::AbstractString, timeout::Real=90.0, request_timeout::Real=5.0, poll_interval::Real=0.1)::ConductorRestartStatus
    all(value -> isfinite(value) && value > 0, (timeout, request_timeout, poll_interval)) || throw(ArgumentError("wait intervals must be positive finite seconds"))
    id = String(operation_id)
    valid_management_uuid(id) || throw(ArgumentError("operation_id must be a canonical UUID"))
    started = time_ns()
    elapsed() = Float64(time_ns() - started) / 1e9
    last = unresolved_conductor_restart(id, :outcome_unknown, "no operation response received")
    while elapsed() < timeout
        remaining = timeout - elapsed()
        remaining <= 0 && break
        try
            last = query_conductor_executor_restart(ip; conductor_port, operation_id=id, timeout=min(request_timeout, remaining))
            last.state != :running && return last
        catch error
            error isa ServerManagementTransportError || error isa ServerManagementProtocolError || rethrow()
            last = unresolved_conductor_restart(id, :outcome_unknown, sprint(showerror, error))
        end
        remaining = timeout - elapsed()
        remaining > 0 && sleep(min(poll_interval, remaining))
    end
    return last
end

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


"""
    SyncopadeResultMessage

Normalized callback result parsed from either legacy `RESULT` or task-aware
`TASK_RESULT` payloads. `task_id` is empty only for the legacy protocol, and
`job_id` may be empty only for a task-aware failure before worker acceptance.
"""
struct SyncopadeResultMessage
    protocol::Symbol
    task_id::String
    job_id::String
    ok::Bool
    payload::String
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


"""
    parse_syncopade_result_payload(payload) -> SyncopadeResultMessage

Parse a checksum-free Syncopade callback payload. Supports legacy `RESULT` and
task-aware `TASK_RESULT` while rejecting missing identifiers, unknown statuses,
and malformed success or error fields.
"""
function parse_syncopade_result_payload(
    payload_value::AbstractString
)::SyncopadeResultMessage
    payload = String(chomp(payload_value))
    parts = split(payload, '|'; keepempty=true)
    isempty(parts) && throw(ArgumentError("empty Syncopade result payload"))

    if parts[1] == "RESULT"
        length(parts) >= 4 || throw(ArgumentError("malformed RESULT payload: $payload"))
        job_id = String(parts[2])
        isempty(job_id) && throw(ArgumentError("RESULT job_id must not be empty"))
        status = parts[3]
        if status == "OK"
            return SyncopadeResultMessage(
                :legacy_result,
                "",
                job_id,
                true,
                String(join(parts[4:end], "|"))
            )
        elseif status == "ERROR"
            length(parts) >= 5 || throw(ArgumentError(
                "malformed RESULT ERROR payload: $payload"
            ))
            error_type = String(parts[4])
            isempty(error_type) && throw(ArgumentError(
                "RESULT error_type must not be empty"
            ))
            return SyncopadeResultMessage(
                :legacy_result,
                "",
                job_id,
                false,
                error_type * "|" * String(join(parts[5:end], "|"))
            )
        end
        throw(ArgumentError("unsupported RESULT status: $status"))
    elseif parts[1] == "TASK_RESULT"
        length(parts) >= 5 || throw(ArgumentError(
            "malformed TASK_RESULT payload: $payload"
        ))
        task_id = String(parts[2])
        isempty(task_id) && throw(ArgumentError("TASK_RESULT task_id must not be empty"))
        job_id = String(parts[3])
        status = parts[4]
        if status == "OK"
            isempty(job_id) && throw(ArgumentError(
                "TASK_RESULT OK job_id must not be empty"
            ))
            return SyncopadeResultMessage(
                :task_result,
                task_id,
                job_id,
                true,
                String(join(parts[5:end], "|"))
            )
        elseif status == "ERROR"
            length(parts) >= 6 || throw(ArgumentError(
                "malformed TASK_RESULT ERROR payload: $payload"
            ))
            error_type = String(parts[5])
            isempty(error_type) && throw(ArgumentError(
                "TASK_RESULT error_type must not be empty"
            ))
            return SyncopadeResultMessage(
                :task_result,
                task_id,
                job_id,
                false,
                error_type * "|" * String(join(parts[6:end], "|"))
            )
        end
        throw(ArgumentError("unsupported TASK_RESULT status: $status"))
    end

    throw(ArgumentError("unsupported Syncopade result prefix: $(parts[1])"))
end


function invoke_syncopade_result_handler(
    handler,
    message::SyncopadeResultMessage
)::Nothing
    args3 = (message.job_id, message.ok, message.payload)
    args4 = (message.task_id, message.job_id, message.ok, message.payload)
    if message.protocol == :task_result
        if applicable(handler, args4...)
            handler(args4...)
        elseif applicable(handler, args3...)
            handler(args3...)
        else
            throw(MethodError(handler, args4))
        end
    elseif message.protocol == :legacy_result
        if applicable(handler, args3...)
            handler(args3...)
        elseif applicable(handler, args4...)
            handler(args4...)
        else
            throw(MethodError(handler, args3))
        end
    else
        throw(ArgumentError("unsupported result protocol: $(message.protocol)"))
    end
    return nothing
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
- `TASK_RESULT|taskId|jobId|OK|value`
- `TASK_RESULT|taskId|jobId|ERROR|errType|errMsg`

# Handler Signature
Legacy handlers keep `handler(jobId::String, ok::Bool, payload::String)`.
Task-aware handlers use `handler(taskId::String, jobId::String, ok::Bool, payload::String)`.
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
                message = parse_syncopade_result_payload(payload)
                invoke_syncopade_result_handler(handler, message)
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
- `TASK_RESULT|taskId|jobId|OK|value`
- `TASK_RESULT|taskId|jobId|ERROR|errType|errMsg`

# Handler Signature
Legacy handlers keep `handler(jobId::String, ok::Bool, payload::String)`.
Task-aware handlers use `handler(taskId::String, jobId::String, ok::Bool, payload::String)`.

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
                    message = parse_syncopade_result_payload(payload)
                    invoke_syncopade_result_handler(handler, message)
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

        message = parse_syncopade_result_payload(payload)
        if message.protocol == :task_result && message.task_id != task_id
            throw(ArgumentError(
                "callback task_id $(message.task_id) does not match submitted task_id $task_id"
            ))
        end
        resolved_task_id = message.protocol == :task_result ? message.task_id : task_id
        return (
            task_id=resolved_task_id,
            job_id=message.job_id,
            ok=message.ok,
            payload=message.payload
        )
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
