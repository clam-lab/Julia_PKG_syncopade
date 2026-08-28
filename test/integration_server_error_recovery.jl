include(joinpath(@__DIR__, "integration_server_busy_rejection.jl"))

const FAILING_PROBE_FUNCTION = "failing_probe"
const FAILURE_PREFIX = "intentional failure: "

function parse_failure_payload(payload::String)
    parts = split(payload, '|'; limit=2)
    length(parts) == 2 || error("malformed error callback payload: $payload")
    parts[1] == "RUNTIME_ERROR" || error("unexpected error type: $(parts[1])")
    startswith(parts[2], FAILURE_PREFIX) ||
        error("unexpected error message: $(parts[2])")

    evidence = parts[2][length(FAILURE_PREFIX)+1:end]
    return parse_probe_payload(String(evidence))
end

function error_recovery_main(args::Vector{String}=ARGS)
    server_ip = length(args) >= 1 ? args[1] : "192.168.100.30"
    server_port = parse_int_arg(args, 2, 8030)
    callback_port_d = parse_int_arg(args, 3, 9151)
    callback_port_r = parse_int_arg(args, 4, 9152)
    callback_port_e = parse_int_arg(args, 5, 9153)
    sleep_seconds = parse_float_arg(args, 6, 3.0)
    timeout = parse_float_arg(args, 7, 15.0)

    length(unique((callback_port_d, callback_port_r, callback_port_e))) == 3 ||
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

    listener_d = listen(callback_ip_addr, callback_port_d)
    listener_r = listen(callback_ip_addr, callback_port_r)
    listener_e = listen(callback_ip_addr, callback_port_e)
    receiver_d = @async receive_callback(listener_d)
    cancel_receiver_r = Ref(false)
    receiver_r = @async begin
        try
            receive_callback(listener_r)
        catch
            cancel_receiver_r[] || rethrow()
            nothing
        end
    end
    receiver_e = @async receive_callback(listener_e)

    try
        client_d = SyncopadeClient(
            server_ip,
            server_port,
            callback_ip,
            callback_port_d,
            PROBE_SOURCE,
            PROBE_MODULE,
            FAILING_PROBE_FUNCTION,
            ["D", string(sleep_seconds)],
        )
        client_r = SyncopadeClient(
            server_ip,
            server_port,
            callback_ip,
            callback_port_r,
            PROBE_SOURCE,
            PROBE_MODULE,
            PROBE_FUNCTION,
            ["R", string(sleep_seconds)],
        )
        client_e = SyncopadeClient(
            server_ip,
            server_port,
            callback_ip,
            callback_port_e,
            PROBE_SOURCE,
            PROBE_MODULE,
            PROBE_FUNCTION,
            ["E", string(sleep_seconds)],
        )

        job_id_d = syncopade_calc_request(client_d)
        status_before_r = wait_for_server_status(
            server_ip,
            server_port,
            "STATUS|busy",
            min(timeout, 5.0),
        )

        rejected_r_ns = time_ns()
        response_r = raw_calc_request(client_r)
        response_r == "ERROR|BUSY" || error("unexpected job R response: $response_r")

        result_d = wait_for_task(receiver_d, timeout, "job D callback")
        result_d.job_id == job_id_d || error("job D callback ID mismatch")
        result_d.ok && error("job D unexpectedly succeeded: $(result_d.payload)")

        probe_d = parse_failure_payload(result_d.payload)
        probe_d.label == "D" || error("unexpected job D label: $(probe_d.label)")
        probe_d.active_at_entry == 1 ||
            error("job D active_at_entry was $(probe_d.active_at_entry)")
        probe_d.max_active == 1 || error("job D max_active was $(probe_d.max_active)")
        probe_d.started_ns < probe_d.finished_ns || error("invalid job D interval")

        elapsed_after_rejection = Float64(time_ns() - rejected_r_ns) / 1.0e9
        remaining_window = max(0.0, rejection_window - elapsed_after_rejection)
        if remaining_window > 0
            r_wait = Base.timedwait(
                () -> istaskdone(receiver_r),
                remaining_window;
                pollint=0.01,
            )
            r_wait === :timed_out || error("job R unexpectedly produced a callback")
        end
        istaskdone(receiver_r) && error("job R unexpectedly produced a callback")

        cancel_receiver_r[] = true
        close_quietly(listener_r)
        r_close_wait = Base.timedwait(() -> istaskdone(receiver_r), 1.0; pollint=0.01)
        r_close_wait === :timed_out && error("job R callback receiver did not close")
        fetch(receiver_r) === nothing || error("unexpected job R receiver result")

        status_after_d = wait_for_server_status(server_ip, server_port, "STATUS|idle", timeout)

        job_id_e = syncopade_calc_request(client_e)
        result_e = wait_for_task(receiver_e, timeout, "job E callback")
        result_e.job_id == job_id_e || error("job E callback ID mismatch")
        result_e.ok || error("job E failed: $(result_e.payload)")

        probe_e = parse_probe_payload(result_e.payload)
        probe_e.label == "E" || error("unexpected job E label: $(probe_e.label)")
        probe_e.active_at_entry == 1 ||
            error("job E active_at_entry was $(probe_e.active_at_entry)")
        probe_e.max_active == 1 || error("job E max_active was $(probe_e.max_active)")
        probe_e.started_ns < probe_e.finished_ns || error("invalid job E interval")
        probe_d.finished_ns <= probe_e.started_ns || error("job D and E intervals overlapped")

        final_status = wait_for_server_status(server_ip, server_port, "STATUS|idle", timeout)

        println("STEP5_RESULT=PASS_ERROR_RECOVERY")
        println("server_endpoint=$(server_ip):$(server_port)")
        println("callback_ip=$(callback_ip)")
        println("initial_status=$(initial_status)")
        println("status_before_r=$(status_before_r)")
        println("job_id_d=$(job_id_d)")
        println("job_r_response=$(response_r)")
        println("callback_r_observed=false")
        println("job_d_error=$(result_d.payload)")
        println("status_after_d=$(status_after_d)")
        println("job_id_e=$(job_id_e)")
        println("probe_e=$(result_e.payload)")
        println("d_e_interval_overlap=false")
        println("final_status=$(final_status)")
        return nothing
    finally
        cancel_receiver_r[] = true
        close_quietly(listener_d)
        close_quietly(listener_r)
        close_quietly(listener_e)
        Base.timedwait(
            () -> istaskdone(receiver_d) && istaskdone(receiver_r) && istaskdone(receiver_e),
            1.0;
            pollint=0.01,
        )
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    error_recovery_main()
end
