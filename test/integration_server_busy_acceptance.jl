using Sockets

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

const PROBE_SOURCE = "server_busy_probe"
const PROBE_MODULE = "SyncopadeServerBusyProbe"
const PROBE_FUNCTION = "busy_probe"

function parse_int_arg(args::Vector{String}, index::Int, default::Int)::Int
    return length(args) >= index ? parse(Int, args[index]) : default
end

function parse_float_arg(args::Vector{String}, index::Int, default::Float64)::Float64
    return length(args) >= index ? parse(Float64, args[index]) : default
end

function wait_for_server_status(
    server_ip::String,
    server_port::Int,
    expected::String,
    timeout::Float64,
)::String
    deadline = time() + timeout
    observed = ""
    while time() < deadline
        observed = try
            query_server_status(server_ip, server_port)
        catch e
            "ERROR:" * sprint(showerror, e)
        end
        observed == expected && return observed
        sleep(0.01)
    end
    error("timeout waiting server status $expected; last=$observed")
end

function wait_for_callbacks(
    result_a::Channel{NamedTuple},
    result_b::Channel{NamedTuple},
    timeout::Float64,
)
    wait_result = Base.timedwait(
        () -> isready(result_a) && isready(result_b),
        timeout;
        pollint=0.01,
    )
    wait_result === :timed_out && error("timeout waiting for both callbacks")
    return take!(result_a), take!(result_b)
end

function parse_probe_payload(payload::String)
    values = Dict{String,String}()
    for field in split(payload, ',')
        pair = split(field, '='; limit=2)
        length(pair) == 2 || error("malformed probe field: $field")
        values[pair[1]] = pair[2]
    end

    required = ("label", "active_at_entry", "max_active", "started_ns", "finished_ns")
    for key in required
        haskey(values, key) || error("probe payload missing $key: $payload")
    end

    return (
        label=values["label"],
        active_at_entry=parse(Int, values["active_at_entry"]),
        max_active=parse(Int, values["max_active"]),
        started_ns=parse(UInt64, values["started_ns"]),
        finished_ns=parse(UInt64, values["finished_ns"]),
    )
end

function main(args::Vector{String}=ARGS)
    server_ip = length(args) >= 1 ? args[1] : "192.168.100.30"
    server_port = parse_int_arg(args, 2, 8030)
    callback_port_a = parse_int_arg(args, 3, 9131)
    callback_port_b = parse_int_arg(args, 4, 9132)
    sleep_seconds = parse_float_arg(args, 5, 3.0)
    timeout = parse_float_arg(args, 6, 15.0)

    callback_port_a != callback_port_b || error("callback ports must be distinct")
    (isfinite(sleep_seconds) && sleep_seconds > 0) ||
        error("sleep_seconds must be finite and > 0")
    (isfinite(timeout) && timeout > sleep_seconds) ||
        error("timeout must be finite and greater than sleep_seconds")

    callback_ip = string(preferred_local_ip())
    callback_ip == server_ip ||
        error("callback IP $callback_ip does not match server IP $server_ip")

    initial_status = query_server_status(server_ip, server_port)
    initial_status == "STATUS|idle" ||
        error("server must be idle before test; observed=$initial_status")

    callback_a = Channel{NamedTuple}(1)
    callback_b = Channel{NamedTuple}(1)
    syncopade_result_server_once(
        callback_port_a,
        (job_id, ok, payload) -> put!(
            callback_a,
            (job_id=job_id, ok=ok, payload=payload, received_ns=time_ns()),
        ),
    )
    syncopade_result_server_once(
        callback_port_b,
        (job_id, ok, payload) -> put!(
            callback_b,
            (job_id=job_id, ok=ok, payload=payload, received_ns=time_ns()),
        ),
    )

    client_a = SyncopadeClient(
        server_ip,
        server_port,
        callback_ip,
        callback_port_a,
        PROBE_SOURCE,
        PROBE_MODULE,
        PROBE_FUNCTION,
        ["A", string(sleep_seconds)],
    )
    client_b = SyncopadeClient(
        server_ip,
        server_port,
        callback_ip,
        callback_port_b,
        PROBE_SOURCE,
        PROBE_MODULE,
        PROBE_FUNCTION,
        ["B", string(sleep_seconds)],
    )

    submitted_a_ns = time_ns()
    job_id_a = syncopade_calc_request(client_a)
    status_before_b = wait_for_server_status(
        server_ip,
        server_port,
        "STATUS|busy",
        min(timeout, 5.0),
    )

    submitted_b_ns = time_ns()
    job_id_b = syncopade_calc_request(client_b)
    accepted_b_ns = time_ns()

    result_a, result_b = wait_for_callbacks(callback_a, callback_b, timeout)
    result_a.job_id == job_id_a || error("job A callback ID mismatch")
    result_b.job_id == job_id_b || error("job B callback ID mismatch")
    result_a.ok || error("job A failed: $(result_a.payload)")
    result_b.ok || error("job B failed: $(result_b.payload)")

    probe_a = parse_probe_payload(result_a.payload)
    probe_b = parse_probe_payload(result_b.payload)
    probe_a.label == "A" || error("unexpected job A label: $(probe_a.label)")
    probe_b.label == "B" || error("unexpected job B label: $(probe_b.label)")

    overlap = max(probe_a.started_ns, probe_b.started_ns) <
              min(probe_a.finished_ns, probe_b.finished_ns)
    max_active = max(probe_a.max_active, probe_b.max_active)
    overlap || error("job intervals did not overlap")
    max_active >= 2 || error("max_active was $max_active, expected >= 2")

    final_status = wait_for_server_status(server_ip, server_port, "STATUS|idle", timeout)

    println("STEP2_RESULT=PASS")
    println("server_endpoint=$(server_ip):$(server_port)")
    println("callback_ip=$(callback_ip)")
    println("initial_status=$(initial_status)")
    println("status_before_b=$(status_before_b)")
    println("job_id_a=$(job_id_a)")
    println("job_id_b=$(job_id_b)")
    println("submitted_a_ns=$(submitted_a_ns)")
    println("submitted_b_ns=$(submitted_b_ns)")
    println("accepted_b_ns=$(accepted_b_ns)")
    println("callback_a_received_ns=$(result_a.received_ns)")
    println("callback_b_received_ns=$(result_b.received_ns)")
    println("probe_a=$(result_a.payload)")
    println("probe_b=$(result_b.payload)")
    println("interval_overlap=$(overlap)")
    println("max_active=$(max_active)")
    println("final_status=$(final_status)")
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
