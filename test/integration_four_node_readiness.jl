"""Explicit one-task readiness probe. Including this file never opens a socket."""
module FourNodeReadiness

using Dates
using SHA
include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

const EXPECTED = "30030.0"
const FIXTURE = joinpath(@__DIR__, "syncopadeBasicTestScript.jl")

function record(io, event; fields...)
    println(io, Dates.now(), " event=", event,
        join((" $key=$(repr(value))" for (key, value) in pairs(fields))))
    flush(io)
end

function checked_payload(row)
    valid, payload = verify_checksum(row)
    valid || error("checksum mismatch")
    return payload
end

function validate_result(mode, accepted_id, message)
    if mode == :direct
        message.protocol == :legacy_result || error("expected RESULT protocol")
        message.job_id == accepted_id || error("callback job ID mismatch")
    else
        message.protocol == :task_result || error("expected TASK_RESULT protocol")
        message.task_id == accepted_id || error("callback task ID mismatch")
    end
    message.ok || error("worker returned ERROR: $(message.payload)")
    message.payload == EXPECTED || error("wrong result: $(repr(message.payload))")
    return message
end

"""Accept and read once under one deadline; close the accepted socket and timer."""
function receive_once(listener, timeout)
    socket = nothing
    expired = Ref(false)
    timer = Timer(timeout) do _
        expired[] = true
        close(listener)
        socket === nothing || close(socket)
    end
    try
        socket = accept(listener)
        peer_ip, _ = getpeername(socket)
        row = readline(socket)
        expired[] && error("callback timed out; computation outcome unknown")
        isempty(row) && error("empty callback")
        return string(peer_ip), row
    catch
        expired[] && error("callback timed out; computation outcome unknown")
        rethrow()
    finally
        close(timer)
        socket === nothing || close(socket)
    end
end

function read_task_status(ip, port, task_id; timeout=5.0)
    row = management_request(ip, port, "TASK_STATUS|$task_id"; timeout)
    return parse_conductor_task_status_response(checked_payload(row))
end

function wait_terminal(ip, port, task_id, job_id, timeout; io)
    deadline = time() + timeout
    while time() < deadline
        status = read_task_status(ip, port, task_id; timeout=min(5.0, max(0.01, deadline-time())))
        status.task_id == task_id || error("TASK_STATUS task ID mismatch")
        status isa KnownConductorTaskStatus || error("conductor forgot accepted task")
        if status.state == :terminal
            record(io, "terminal"; status)
            status.job_id == job_id || error("terminal job ID mismatch")
            status.terminal_kind == "WORKER_DONE_OK" || error("abnormal terminal kind")
            return status
        end
        sleep(0.05)
    end
    error("terminal confirmation timed out; outcome unknown")
end

function wait_idle(ip, port, before, timeout; io)
    deadline = time() + timeout
    while time() < deadline
        after = query_server_runtime(ip; server_port=port, timeout=min(5.0, max(0.01, deadline-time())))
        after.listener_id == before.listener_id || error("listener identity changed")
        after.server_id == before.server_id || error("executor identity changed")
        if after.ready && after.state == :idle
            record(io, "idle_restored"; ip, port, runtime=after)
            return after
        end
        after.state == :busy || error("unexpected worker state: $(after.state)")
        sleep(0.05)
    end
    error("idle confirmation timed out")
end

function validate_inputs(mode, target_ip, target_port, callback_ip, callback_port, source, timeout)
    mode in (:direct, :conductor) || error("mode must be direct or conductor")
    parse(IPv4, target_ip)
    parse(IPv4, callback_ip)
    prefix = join(split(target_ip, '.')[1:3], '.') * "."
    startswith(callback_ip, prefix) || error("callback must use the selected LAN")
    1 <= target_port <= 65535 || error("invalid target port")
    0 <= callback_port <= 65535 || error("invalid callback port")
    isfinite(timeout) && timeout > 0 || error("timeout must be positive and finite")
    isabspath(source) || error("source must be absolute")
    occursin(r"[|:\r\n]", source) && error("source contains protocol separator")
    digest = bytes2hex(open(sha256, source))
    digest == bytes2hex(open(sha256, FIXTURE)) || error("source differs from repository fixture")
    return digest
end

"""
Run one task, never retry. The caller explicitly selects both LAN endpoints.
Normal return proves result identity/value, unchanged worker IDs, idle recovery,
and (for conductor mode) the matching WORKER_DONE_OK terminal record.
All sockets have deadlines; failure is reconciled read-only and rethrown.
"""
function run_probe(mode, target_ip, target_port, callback_ip, callback_port, source, timeout; io=stdout)
    digest = validate_inputs(mode, target_ip, target_port, callback_ip, callback_port, source, timeout)
    request_timeout = min(5.0, timeout)
    record(io, "begin"; mode, target_ip, target_port, callback_ip, source, sha256=digest, timeout)
    snapshots = Dict{Tuple{String,Int},ServerRuntimeInfo}()
    candidates = if mode == :direct
        [(target_ip, target_port)]
    else
        row = management_request(target_ip, target_port, "LIST"; timeout=request_timeout)
        payload = checked_payload(row)
        startswith(payload, "NODES|") || error("invalid LIST response")
        record(io, "idle_list"; payload)
        parse_conductor_nodes(row)
    end
    isempty(candidates) && error("no idle candidates")
    prefix = join(split(target_ip, '.')[1:3], '.') * "."
    all(endpoint -> startswith(endpoint[1], prefix), candidates) || error("LIST contains another LAN")
    length(unique(first.(candidates))) == length(candidates) || error("ambiguous worker IPs in LIST")
    for (ip, port) in candidates
        before = query_server_runtime(ip; server_port=port, timeout=request_timeout)
        record(io, "before"; ip, port, runtime=before)
        before.ready && before.state == :idle || error("candidate is not idle/ready: $ip:$port")
        snapshots[(ip, port)] = before
    end

    listener = listen(parse(IPv4, callback_ip), callback_port)
    bound_port = Int(getsockname(listener)[2])
    accepted_id = ""
    submission_attempted = false
    try
        record(io, "callback_listening"; callback_ip, bound_port)
        fields = String[callback_ip, string(bound_port),
            "$source:syncopadeBasicTestScript:test", "[2,3,5]", "[7,11,13]"]
        mode == :conductor && pushfirst!(fields, "SUBMIT")
        submission_attempted = true
        row = management_request(target_ip, target_port, join(fields, '|'); timeout=request_timeout)
        record(io, "acceptance_response"; row)
        if mode == :direct
            reply = parse_worker_start_response(row)
            reply isa WorkerStartAccepted || error("worker rejected task as busy")
            accepted_id = reply.job_id
        else
            parts = split(checked_payload(row), '|')
            length(parts) == 3 && parts[1:2] == ["OK", "QUEUED"] && !isempty(parts[3]) ||
                error("conductor did not accept task")
            accepted_id = String(parts[3])
        end
        record(io, "accepted"; accepted_id)
        peer_ip, callback_row = receive_once(listener, timeout)
        record(io, "callback"; peer_ip, row=callback_row)
        message = validate_result(mode, accepted_id,
            parse_syncopade_result_payload(checked_payload(callback_row)))
        matches = filter(endpoint -> endpoint[1] == peer_ip, candidates)
        length(matches) == 1 || error("callback peer does not identify one prechecked worker")
        worker_ip, worker_port = only(matches)
        record(io, "worker_identified"; worker_ip, worker_port, task_id=message.task_id, job_id=message.job_id)
        mode == :conductor && wait_terminal(target_ip, target_port,
            message.task_id, message.job_id, timeout; io)
        wait_idle(worker_ip, worker_port, snapshots[(worker_ip, worker_port)], timeout; io)
        record(io, "result_verified"; task_id=message.task_id, job_id=message.job_id, value=message.payload)
        return (; task_id=message.task_id, job_id=message.job_id, worker_ip, worker_port,
            callback_port=bound_port, result=message.payload)
    catch exception
        record(io, "failure"; message=sprint(showerror, exception), submission_attempted,
            accepted_id, outcome="not assumed unexecuted; never resend automatically")
        if submission_attempted
            if mode == :conductor && !isempty(accepted_id)
                try
                    record(io, "reconcile_task"; status=read_task_status(target_ip, target_port,
                        accepted_id; timeout=request_timeout))
                catch query_error
                    record(io, "reconcile_task_failed"; message=sprint(showerror, query_error))
                end
            end
            for (ip, port) in candidates
                try
                    record(io, "reconcile_runtime"; ip, port,
                        runtime=query_server_runtime(ip; server_port=port, timeout=request_timeout))
                catch query_error
                    record(io, "reconcile_runtime_failed"; ip, port, message=sprint(showerror, query_error))
                end
            end
        end
        rethrow()
    finally
        close(listener)
        # This is our own ephemeral callback endpoint, not a production port.
        replacement = listen(parse(IPv4, callback_ip), bound_port)
        close(replacement)
        record(io, "callback_closed_and_rebind_verified"; callback_ip, bound_port)
    end
end

function main(args)
    length(args) == 8 || error("usage: direct|conductor target_ip target_port callback_ip callback_port absolute_source timeout log_path")
    mode, target_ip, port, callback_ip, callback_port, source, timeout, log_path = args
    ispath(log_path) && error("refusing to overwrite log: $log_path")
    open(log_path, "w") do io
        try
            result = run_probe(Symbol(mode), target_ip, parse(Int, port), callback_ip,
                parse(Int, callback_port), source, parse(Float64, timeout); io)
            record(io, "PASS"; result)
            println("PASS ", repr(result), " log=", abspath(log_path))
        catch exception
            record(io, "FAIL"; message=sprint(showerror, exception))
            rethrow()
        end
    end
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    FourNodeReadiness.main(ARGS)
end
