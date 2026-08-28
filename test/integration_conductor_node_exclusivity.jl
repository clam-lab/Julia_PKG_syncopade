using Dates
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

        job_id = parts[2]
        status = parts[3]
        if status == "OK"
            return (job_id=job_id, ok=true, payload=join(parts[4:end], "|"))
        elseif status == "ERROR" && length(parts) >= 5
            return (
                job_id=job_id,
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

function wait_for_tasks(tasks::Vector{Task}, timeout::Float64, label::String)
    result = Base.timedwait(() -> all(istaskdone, tasks), timeout; pollint=0.01)
    result === :timed_out && error("timeout waiting for $label")
    return nothing
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

function count_interval_overlaps(intervals)::Int
    count = 0
    for i in eachindex(intervals)
        start_i, finish_i = intervals[i]
        start_i < finish_i || error("invalid interval at index $i")
        for j in (i + 1):length(intervals)
            start_j, finish_j = intervals[j]
            max(start_i, start_j) < min(finish_i, finish_j) && (count += 1)
        end
    end
    return count
end

function parse_csv_line(line::String)::Vector{String}
    fields = String[]
    buffer = IOBuffer()
    in_quotes = false
    index = firstindex(line)
    while index <= lastindex(line)
        char = line[index]
        if char == '"'
            next_index = nextind(line, index)
            if in_quotes && next_index <= lastindex(line) && line[next_index] == '"'
                write(buffer, '"')
                index = next_index
            else
                in_quotes = !in_quotes
            end
        elseif char == ',' && !in_quotes
            push!(fields, String(take!(buffer)))
        else
            write(buffer, char)
        end
        index = nextind(line, index)
    end
    in_quotes && error("unterminated CSV quote")
    push!(fields, String(take!(buffer)))
    return fields
end

function read_conductor_events(path::String)
    lines = readlines(path)
    isempty(lines) && return Dict{String,String}[]
    header = parse_csv_line(lines[1])
    events = Dict{String,String}[]
    for (offset, line) in enumerate(lines[2:end])
        line_number = offset + 1
        isempty(line) && continue
        fields = parse_csv_line(line)
        length(fields) == length(header) ||
            error("CSV column mismatch at line $line_number")
        push!(events, Dict(header .=> fields))
    end
    return events
end

function wait_for_conductor_events(
    path::String,
    task_ids::Vector{String},
    timeout::Float64,
)
    deadline = time() + timeout
    last_error = ""
    while time() < deadline
        events = try
            read_conductor_events(path)
        catch e
            last_error = sprint(showerror, e)
            sleep(0.05)
            continue
        end

        dispatch_ids = Set(
            event["task_id"] for event in events if event["event"] == "DISPATCH_OK"
        )
        done_ids = Set(
            event["task_id"] for event in events if event["event"] == "TASK_DONE"
        )
        if all(task_id -> task_id in dispatch_ids && task_id in done_ids, task_ids)
            return events
        end
        sleep(0.05)
    end
    error("timeout waiting conductor events; last_error=$last_error")
end

function validate_conductor_events(
    events,
    task_ids::Vector{String},
    callbacks,
    worker_ip::String,
    worker_port::Int,
)
    intervals = Tuple{Int64,Int64}[]
    for index in eachindex(task_ids)
        task_id = task_ids[index]
        job_id = callbacks[index].job_id
        dispatch_rows = [
            event for event in events if
            event["event"] == "DISPATCH_OK" && event["task_id"] == task_id
        ]
        done_rows = [
            event for event in events if
            event["event"] == "TASK_DONE" && event["task_id"] == task_id
        ]
        length(dispatch_rows) == 1 ||
            error("expected one DISPATCH_OK for task $task_id; found $(length(dispatch_rows))")
        length(done_rows) == 1 ||
            error("expected one TASK_DONE for task $task_id; found $(length(done_rows))")

        dispatch_row = only(dispatch_rows)
        done_row = only(done_rows)
        dispatch_row["job_id"] == job_id || error("DISPATCH_OK job ID mismatch")
        done_row["job_id"] == job_id || error("TASK_DONE job ID mismatch")
        dispatch_row["node_ip"] == worker_ip || error("DISPATCH_OK worker IP mismatch")
        dispatch_row["node_port"] == string(worker_port) ||
            error("DISPATCH_OK worker port mismatch")
        done_row["node_ip"] == worker_ip || error("TASK_DONE worker IP mismatch")
        done_row["node_port"] == string(worker_port) || error("TASK_DONE worker port mismatch")
        done_row["status"] == "OK" || error("TASK_DONE status was $(done_row["status"])")
        done_row["callback_ok"] == "true" || error("TASK_DONE callback was not successful")

        started = DateTime(done_row["started_at"], dateformat"yyyy-mm-ddTHH:MM:SS.sss")
        finished = DateTime(done_row["finished_at"], dateformat"yyyy-mm-ddTHH:MM:SS.sss")
        push!(intervals, (Dates.value(started), Dates.value(finished)))
    end
    return intervals
end

function main(args::Vector{String}=ARGS)
    conductor_ip = length(args) >= 1 ? args[1] : "192.168.100.30"
    conductor_port = parse_int_arg(args, 2, 9030)
    server_ip = length(args) >= 3 ? args[3] : "192.168.100.30"
    server_port = parse_int_arg(args, 4, 8030)
    task_count = parse_int_arg(args, 5, 20)
    callback_base_port = parse_int_arg(args, 6, 9200)
    sleep_seconds = parse_float_arg(args, 7, 3.0)
    timeout = parse_float_arg(args, 8, 90.0)
    conductor_log_path = length(args) >= 9 ? args[9] : get(ENV, "SYNCOPADE_CONDUCTOR_LOG", "")

    task_count >= 2 || error("task_count must be >= 2")
    callback_base_port > 0 || error("callback_base_port must be > 0")
    callback_base_port + task_count <= 65535 || error("callback port range is invalid")
    (isfinite(sleep_seconds) && sleep_seconds > 0) ||
        error("sleep_seconds must be finite and > 0")
    (isfinite(timeout) && timeout > task_count * sleep_seconds) ||
        error("timeout must exceed serial execution time")
    isempty(conductor_log_path) && error("conductor event log path is required")

    callback_ip_addr = preferred_local_ip()
    callback_ip = string(callback_ip_addr)
    callback_ip == conductor_ip || error("callback IP does not match conductor IP")
    callback_ip == server_ip || error("callback IP does not match server IP")

    initial_status = query_server_status(server_ip, server_port)
    initial_status == "STATUS|idle" ||
        error("server must be idle before test; observed=$initial_status")
    node_payload = query_conductor_nodes(conductor_ip; conductor_port=conductor_port)
    idle_nodes = parse_conductor_nodes(node_payload)
    idle_nodes == [(server_ip, server_port)] ||
        error("fail-closed: unexpected idle nodes $(repr(idle_nodes))")

    callback_ports = [callback_base_port + index for index in 1:task_count]
    listeners = Sockets.TCPServer[]
    receiver_tasks = Task[]
    try
        for port in callback_ports
            push!(listeners, listen(callback_ip_addr, port))
        end
        for listener in listeners
            push!(receiver_tasks, @async receive_callback(listener))
        end

        gate = Base.Event()
        ready = Channel{Nothing}(task_count)
        submit_tasks = Task[]
        for index in 1:task_count
            label = "run-" * lpad(string(index), 4, '0')
            callback_port = callback_ports[index]
            submit_task = @async begin
                put!(ready, nothing)
                wait(gate)
                submit_conductor_task(
                    conductor_ip;
                    conductor_port=conductor_port,
                    coordinator_ip=callback_ip,
                    coordinator_port=callback_port,
                    source=PROBE_SOURCE,
                    module_name=PROBE_MODULE,
                    function_name=PROBE_FUNCTION,
                    args=[label, string(sleep_seconds)],
                )
            end
            push!(submit_tasks, submit_task)
        end

        for _ in 1:task_count
            take!(ready)
        end
        submit_gate_opened_ns = time_ns()
        notify(gate)

        wait_for_tasks(submit_tasks, min(timeout, 15.0), "SUBMIT responses")
        task_ids = String[fetch(task) for task in submit_tasks]
        length(unique(task_ids)) == task_count || error("conductor task IDs are not unique")

        wait_for_tasks(receiver_tasks, timeout, "callbacks")
        callbacks = [fetch(task) for task in receiver_tasks]
        all(callback -> callback.ok, callbacks) || error("one or more callbacks returned ERROR")
        job_ids = String[callback.job_id for callback in callbacks]
        length(unique(job_ids)) == task_count || error("worker job IDs are not unique")

        probes = [parse_probe_payload(callback.payload) for callback in callbacks]
        for index in 1:task_count
            expected_label = "run-" * lpad(string(index), 4, '0')
            probes[index].label == expected_label ||
                error("callback label mismatch at index $index")
        end

        fixture_intervals = [(probe.started_ns, probe.finished_ns) for probe in probes]
        fixture_overlap_count = count_interval_overlaps(fixture_intervals)
        max_active = maximum(probe.max_active for probe in probes)

        events = wait_for_conductor_events(conductor_log_path, task_ids, timeout)
        conductor_intervals = validate_conductor_events(
            events,
            task_ids,
            callbacks,
            server_ip,
            server_port,
        )
        conductor_overlap_count = count_interval_overlaps(conductor_intervals)

        final_status = query_server_status(server_ip, server_port)
        final_status == "STATUS|idle" || error("server did not return idle: $final_status")
        max_active >= 2 || error("overlap not reproduced: max_active=$max_active")
        fixture_overlap_count >= 1 || error("fixture intervals did not overlap")
        conductor_overlap_count >= 1 || error("conductor intervals did not overlap")

        println("STEP3_RESULT=PASS_REPRODUCED")
        println("conductor_endpoint=$(conductor_ip):$(conductor_port)")
        println("server_endpoint=$(server_ip):$(server_port)")
        println("callback_ip=$(callback_ip)")
        println("initial_status=$(initial_status)")
        println("initial_idle_nodes=$(repr(idle_nodes))")
        println("planned=$(task_count)")
        println("submitted=$(length(task_ids))")
        println("callbacks=$(length(callbacks))")
        println("unique_task_ids=$(length(unique(task_ids)))")
        println("unique_job_ids=$(length(unique(job_ids)))")
        println("submit_gate_opened_ns=$(submit_gate_opened_ns)")
        println("max_active=$(max_active)")
        println("fixture_overlap_pairs=$(fixture_overlap_count)")
        println("conductor_overlap_pairs=$(conductor_overlap_count)")
        println("final_status=$(final_status)")
        println("conductor_log=$(conductor_log_path)")
        for index in 1:task_count
            probe = probes[index]
            println(
                "RESULT index=$(index) callback_port=$(callback_ports[index]) " *
                "task_id=$(task_ids[index]) job_id=$(callbacks[index].job_id) " *
                "label=$(probe.label) active_at_entry=$(probe.active_at_entry) " *
                "max_active=$(probe.max_active) started_ns=$(probe.started_ns) " *
                "finished_ns=$(probe.finished_ns)",
            )
        end
        return nothing
    finally
        for listener in listeners
            close_quietly(listener)
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
