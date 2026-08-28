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

function close_quietly(io)
    try
        close(io)
    catch
    end
    return nothing
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

function wait_for_task(task::Task, timeout::Float64, label::String)
    result = Base.timedwait(() -> istaskdone(task), timeout; pollint=0.01)
    result === :timed_out && error("timeout waiting for $label")
    return fetch(task)
end

function receive_callback(listener::Sockets.TCPServer)
    sock = nothing
    try
        sock = accept(listener)
        line = readline(sock)
        checksum_ok, payload = verify_checksum(line)
        checksum_ok || error("invalid callback checksum: $line")

        parts = split(payload, '|')
        length(parts) >= 4 || error("malformed callback payload: $payload")
        parts[1] == "RESULT" || error("unexpected callback type: $(parts[1])")

        if parts[3] == "OK"
            return (job_id=parts[2], ok=true, payload=join(parts[4:end], "|"))
        elseif parts[3] == "ERROR" && length(parts) >= 5
            return (
                job_id=parts[2],
                ok=false,
                payload=parts[4] * "|" * join(parts[5:end], "|"),
            )
        end
        error("unexpected callback status: $payload")
    finally
        sock === nothing || close_quietly(sock)
        close_quietly(listener)
    end
end

function raw_calc_request(client::SyncopadeClient)::String
    func_spec = string(client.file_name, ":", client.module_name, ":", client.function_name)
    payload_parts = String[client.self_ip_addr, string(client.self_port), func_spec]
    append!(payload_parts, client.args)
    request = add_checksum(join(payload_parts, "|"))

    sock = connect(client.server_ip_addr, client.server_port)
    try
        println(sock, request)
        return readline(sock)
    finally
        close_quietly(sock)
    end
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
    callback_port_a = parse_int_arg(args, 3, 9141)
    callback_port_b = parse_int_arg(args, 4, 9142)
    sleep_seconds = parse_float_arg(args, 5, 3.0)
    timeout = parse_float_arg(args, 6, 15.0)
    callback_port_c = parse_int_arg(args, 7, 9143)

    length(unique((callback_port_a, callback_port_b, callback_port_c))) == 3 ||
        error("callback ports must be distinct")
    (isfinite(sleep_seconds) && sleep_seconds > 0) ||
        error("sleep_seconds must be finite and > 0")
    rejection_window = sleep_seconds + 1.0
    (isfinite(timeout) && timeout > rejection_window) ||
        error("timeout must exceed the rejection observation window")

    callback_ip_addr = preferred_local_ip()
    callback_ip = string(callback_ip_addr)
    callback_ip == server_ip ||
        error("callback IP $callback_ip does not match server IP $server_ip")

    initial_status = query_server_status(server_ip, server_port)
    initial_status == "STATUS|idle" ||
        error("server must be idle before test; observed=$initial_status")

    listener_a = listen(callback_ip_addr, callback_port_a)
    listener_b = listen(callback_ip_addr, callback_port_b)
    listener_c = listen(callback_ip_addr, callback_port_c)
    receiver_a = @async receive_callback(listener_a)
    cancel_receiver_b = Ref(false)
    receiver_b = @async begin
        try
            receive_callback(listener_b)
        catch
            cancel_receiver_b[] || rethrow()
            nothing
        end
    end
    receiver_c = @async receive_callback(listener_c)

    try
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
        client_c = SyncopadeClient(
            server_ip,
            server_port,
            callback_ip,
            callback_port_c,
            PROBE_SOURCE,
            PROBE_MODULE,
            PROBE_FUNCTION,
            ["C", string(sleep_seconds)],
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
        response_b = raw_calc_request(client_b)
        rejected_b_ns = time_ns()
        response_b == "ERROR|BUSY" || error("unexpected job B response: $response_b")

        result_a = wait_for_task(receiver_a, timeout, "job A callback")
        result_a.job_id == job_id_a || error("job A callback ID mismatch")
        result_a.ok || error("job A failed: $(result_a.payload)")

        elapsed_after_rejection = Float64(time_ns() - rejected_b_ns) / 1.0e9
        remaining_window = max(0.0, rejection_window - elapsed_after_rejection)
        if remaining_window > 0
            b_wait = Base.timedwait(
                () -> istaskdone(receiver_b),
                remaining_window;
                pollint=0.01,
            )
            b_wait === :timed_out || error("job B unexpectedly produced a callback")
        end
        istaskdone(receiver_b) && error("job B unexpectedly produced a callback")

        cancel_receiver_b[] = true
        close_quietly(listener_b)
        b_close_wait = Base.timedwait(() -> istaskdone(receiver_b), 1.0; pollint=0.01)
        b_close_wait === :timed_out && error("job B callback receiver did not close")
        fetch(receiver_b) === nothing || error("unexpected job B receiver result")

        probe_a = parse_probe_payload(result_a.payload)
        probe_a.label == "A" || error("unexpected job A label: $(probe_a.label)")
        probe_a.active_at_entry == 1 ||
            error("job A active_at_entry was $(probe_a.active_at_entry)")
        probe_a.max_active == 1 || error("job A max_active was $(probe_a.max_active)")
        probe_a.started_ns < probe_a.finished_ns || error("invalid job A interval")

        status_after_a = wait_for_server_status(server_ip, server_port, "STATUS|idle", timeout)

        submitted_c_ns = time_ns()
        job_id_c = syncopade_calc_request(client_c)
        result_c = wait_for_task(receiver_c, timeout, "job C callback")
        result_c.job_id == job_id_c || error("job C callback ID mismatch")
        result_c.ok || error("job C failed: $(result_c.payload)")

        probe_c = parse_probe_payload(result_c.payload)
        probe_c.label == "C" || error("unexpected job C label: $(probe_c.label)")
        probe_c.active_at_entry == 1 ||
            error("job C active_at_entry was $(probe_c.active_at_entry)")
        probe_c.max_active == 1 || error("job C max_active was $(probe_c.max_active)")
        probe_c.started_ns < probe_c.finished_ns || error("invalid job C interval")

        intervals_overlap = probe_a.finished_ns > probe_c.started_ns
        intervals_overlap && error("job A and C intervals overlapped")

        final_status = wait_for_server_status(server_ip, server_port, "STATUS|idle", timeout)

        println("STEP3_RESULT=PASS_BUSY_REJECTED")
        println("STEP4_RESULT=PASS_NORMAL_RECOVERY")
        println("server_endpoint=$(server_ip):$(server_port)")
        println("callback_ip=$(callback_ip)")
        println("initial_status=$(initial_status)")
        println("status_before_b=$(status_before_b)")
        println("job_id_a=$(job_id_a)")
        println("job_id_c=$(job_id_c)")
        println("job_b_response=$(response_b)")
        println("submitted_a_ns=$(submitted_a_ns)")
        println("submitted_b_ns=$(submitted_b_ns)")
        println("rejected_b_ns=$(rejected_b_ns)")
        println("submitted_c_ns=$(submitted_c_ns)")
        println("callback_b_observed=false")
        println("probe_a=$(result_a.payload)")
        println("status_after_a=$(status_after_a)")
        println("probe_c=$(result_c.payload)")
        println("a_c_interval_overlap=$(intervals_overlap)")
        println("final_status=$(final_status)")
        return nothing
    finally
        cancel_receiver_b[] = true
        close_quietly(listener_a)
        close_quietly(listener_b)
        close_quietly(listener_c)
        Base.timedwait(
            () -> istaskdone(receiver_a) && istaskdone(receiver_b) && istaskdone(receiver_c),
            1.0;
            pollint=0.01,
        )
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
