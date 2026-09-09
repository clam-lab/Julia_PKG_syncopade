include("syncopadeClient.jl")
include("syncopadeNodeConfig.jl")
using Dates
using Sockets
using UUIDs

# shared state for conductor
const node_states_lock = ReentrantLock()
const task_queue_lock = ReentrantLock()
const dispatch_lock = ReentrantLock()

struct NODES
    IP::String
    port::Int
    name::String
end

struct ConductorTask
    task_id::String
    coordinator_ip::String
    coordinator_port::Int
    source::String
    module_name::String
    function_name::String
    args::Vector{String}
    retry_count::Int
end

const NODE_IDLE = :idle
const NODE_BUSY = :busy
const NODE_DOWN = :down
const NODE_RESERVED = :reserved

@enum DispatchOutcome begin
    DISPATCH_ACCEPTED
    DISPATCH_BUSY_REJECTED
    DISPATCH_FAILED
    DISPATCH_OUTCOME_UNKNOWN
end

struct NodeRuntimeState
    state::Symbol
    generation::UInt64
    task_id::String
    job_id::String
end

struct NodeObservation
    node::NODES
    state::Symbol
    expected_generation::UInt64
end

const node_states = Dict{Tuple{String,Int},NodeRuntimeState}()
const task_queue = ConductorTask[]

const DEFAULT_POLL_INTERVAL = 2.0  # seconds
const DEFAULT_STATUS_TIMEOUT = 0.2  # seconds (per node)
const DEFAULT_CACHE_CLEAR_TIMEOUT = 1.0  # seconds (per node)
const DEFAULT_MAX_RETRY = 3
const DEFAULT_DISPATCH_TIMEOUT = 3.0  # seconds (worker start-ack timeout)
const DEFAULT_CONDUCTOR_LOG_PATH = joinpath(@__DIR__, "logs", "conductor_events.csv")
const DEFAULT_LOG_BATCH_SIZE = 64
const DEFAULT_LOG_FLUSH_INTERVAL_SEC = 0.1
const DEFAULT_LOG_CHANNEL_CAPACITY = 4096
const CONDUCTOR_LOG_COLUMNS = (
    "timestamp",
    "event",
    "task_id",
    "retry",
    "node_name",
    "node_ip",
    "node_port",
    "job_id",
    "queue_len",
    "state_from",
    "state_to",
    "source",
    "module_name",
    "function_name",
    "arg_count",
    "coordinator_ip",
    "coordinator_port",
    "status",
    "started_at",
    "finished_at",
    "callback_ok",
    "error",
)
const conductor_log_lock = ReentrantLock()
const conductor_log_channel = Ref{Union{Nothing,Channel{Union{Nothing,String}}}}(nothing)
const conductor_log_task = Ref{Union{Nothing,Task}}(nothing)
const conductor_log_atexit_registered = Ref(false)
const conductor_log_drop_count = Ref(0)

function conductor_log_path()::String
    return get(ENV, "SYNCOPADE_CONDUCTOR_LOG", DEFAULT_CONDUCTOR_LOG_PATH)
end

function csv_escape(v)::String
    s = String(v)
    s = replace(s, "\r\n" => "\n")
    s = replace(s, "\r" => "\n")
    s = replace(s, "\"" => "\"\"")
    return "\"" * s * "\""
end

function start_conductor_log_writer!()
    path = conductor_log_path()
    mkpath(dirname(path))

    needs_header = !isfile(path) || filesize(path) == 0
    io = open(path, "a")
    if needs_header
        println(io, join(CONDUCTOR_LOG_COLUMNS, ","))
        flush(io)
    end

    ch = Channel{Union{Nothing,String}}(DEFAULT_LOG_CHANNEL_CAPACITY)
    task = @async begin
        try
            batch = String[]
            while true
                item = take!(ch)
                stop_requested = item === nothing
                if !stop_requested
                    push!(batch, item)
                end

                window_start = time()
                while !stop_requested && length(batch) < DEFAULT_LOG_BATCH_SIZE
                    remaining = DEFAULT_LOG_FLUSH_INTERVAL_SEC - (time() - window_start)
                    if remaining <= 0
                        break
                    end
                    w = Base.timedwait(() -> isready(ch), remaining; pollint=min(0.01, remaining))
                    if w === :timed_out
                        break
                    end
                    while isready(ch) && length(batch) < DEFAULT_LOG_BATCH_SIZE
                        next_item = take!(ch)
                        if next_item === nothing
                            stop_requested = true
                            break
                        end
                        push!(batch, next_item)
                    end
                end

                if !isempty(batch)
                    write(io, join(batch, "\n"))
                    write(io, "\n")
                    flush(io)
                    empty!(batch)
                end

                if stop_requested
                    break
                end
            end
        catch e
            println("Conductor log writer error: ", e)
        finally
            try
                close(io)
            catch
            end
        end
    end

    conductor_log_channel[] = ch
    conductor_log_task[] = task
end

function ensure_conductor_log_writer!()
    lock(conductor_log_lock) do
        if conductor_log_task[] !== nothing && istaskdone(conductor_log_task[])
            conductor_log_channel[] = nothing
            conductor_log_task[] = nothing
        end
        if conductor_log_channel[] === nothing
            start_conductor_log_writer!()
            if !conductor_log_atexit_registered[]
                atexit(stop_conductor_log_writer!)
                conductor_log_atexit_registered[] = true
            end
        end
    end
end

function stop_conductor_log_writer!()
    task = nothing
    lock(conductor_log_lock) do
        ch = conductor_log_channel[]
        if ch !== nothing
            try
                put!(ch, nothing)
            catch
            end
        end
        task = conductor_log_task[]
        conductor_log_channel[] = nothing
        conductor_log_task[] = nothing
    end
    if task !== nothing
        try
            wait(task)
        catch
        end
    end
end

function enqueue_log_line!(line::String)::Bool
    ensure_conductor_log_writer!()
    lock(conductor_log_lock) do
        ch = conductor_log_channel[]
        if ch === nothing
            return false
        end

        if isfull(ch)
            conductor_log_drop_count[] += 1
            if conductor_log_drop_count[] % 100 == 1
                println("🐖🐖🐖 Conductor log queue full; dropped=", conductor_log_drop_count[])
            end
            return false
        end

        try
            put!(ch, line)
            return true
        catch
            return false
        end
    end
end

function log_conductor_event(event::String; kwargs...)
    row = String[
        Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS.sss"),
        event,
        string(get(kwargs, :task_id, "")),
        string(get(kwargs, :retry, "")),
        string(get(kwargs, :node_name, "")),
        string(get(kwargs, :node_ip, "")),
        string(get(kwargs, :node_port, "")),
        string(get(kwargs, :job_id, "")),
        string(get(kwargs, :queue_len, "")),
        string(get(kwargs, :state_from, "")),
        string(get(kwargs, :state_to, "")),
        string(get(kwargs, :source, "")),
        string(get(kwargs, :module_name, "")),
        string(get(kwargs, :function_name, "")),
        string(get(kwargs, :arg_count, "")),
        string(get(kwargs, :coordinator_ip, "")),
        string(get(kwargs, :coordinator_port, "")),
        string(get(kwargs, :status, "")),
        string(get(kwargs, :started_at, "")),
        string(get(kwargs, :finished_at, "")),
        string(get(kwargs, :callback_ok, "")),
        string(get(kwargs, :error, "")),
    ]

    enqueue_log_line!(join(csv_escape.(row), ","))
end

function log_task_event(event::String, task::ConductorTask; kwargs...)
    base = (
        task_id=task.task_id,
        retry=task.retry_count,
        source=task.source,
        module_name=task.module_name,
        function_name=task.function_name,
        arg_count=length(task.args),
        coordinator_ip=task.coordinator_ip,
        coordinator_port=task.coordinator_port,
    )
    log_conductor_event(event; base..., kwargs...)
end

function find_node_by_endpoint(ip::AbstractString, port::Int)::NODES
    ip_s = String(ip)
    for e in configured_node_entries()
        if e.ip == ip_s && e.port == port
            return NODES(e.ip, e.port, e.name)
        end
    end
    return NODES(ip_s, port, "unknown")
end

function apply_done_to_node!(node::NODES, task_id::String, job_id::String)::NamedTuple
    released = false
    reason = :untracked_endpoint
    previous = default_node_runtime_state()
    lock(node_states_lock) do
        key = (node.IP, node.port)
        if haskey(node_states, key)
            current = node_states[key]
            previous = current
            if isempty(current.task_id)
                reason = :no_assignment
            elseif current.task_id != task_id
                reason = :task_mismatch
            elseif isempty(job_id)
                reason = :job_mismatch
            elseif current.state == NODE_BUSY
                if current.job_id == job_id
                    node_states[key] = NodeRuntimeState(
                        NODE_IDLE,
                        current.generation + UInt64(1),
                        "",
                        ""
                    )
                    released = true
                    reason = :matched
                else
                    reason = :job_mismatch
                end
            elseif current.state == NODE_RESERVED && isempty(current.job_id)
                node_states[key] = NodeRuntimeState(
                    NODE_IDLE,
                    current.generation + UInt64(1),
                    "",
                    ""
                )
                released = true
                reason = :early_done
            else
                reason = :state_mismatch
            end
        end
    end
    released && log_node_state_change(node, previous.state, NODE_IDLE)
    return (released=released, reason=reason, previous=previous)
end

function handle_done_payload(payload::String)::Bool
    parts = split(payload, '|')
    if length(parts) < 10 || parts[1] != "DONE"
        throw(ArgumentError("Invalid DONE format"))
    end

    task_id = String(parts[2])
    job_id = String(parts[3])
    worker_ip = String(parts[4])
    worker_port = parse(Int, parts[5])
    status = String(parts[6])
    started_at = String(parts[7])
    finished_at = String(parts[8])
    callback_ok = String(parts[9])
    error_msg = String(join(parts[10:end], "|"))

    node = find_node_by_endpoint(worker_ip, worker_port)
    result = apply_done_to_node!(node, task_id, job_id)
    if result.released
        log_conductor_event(
            "TASK_DONE";
            task_id=task_id,
            node_name=node.name,
            node_ip=node.IP,
            node_port=node.port,
            job_id=job_id,
            queue_len=queue_len(),
            status=status,
            started_at=started_at,
            finished_at=finished_at,
            callback_ok=callback_ok,
            error=error_msg
        )
        return true
    end

    previous = result.previous
    log_conductor_event(
        "DONE_IGNORED";
        task_id=task_id,
        node_name=node.name,
        node_ip=node.IP,
        node_port=node.port,
        job_id=job_id,
        queue_len=queue_len(),
        state_from=string(previous.state),
        state_to=string(previous.state),
        status=status,
        started_at=started_at,
        finished_at=finished_at,
        callback_ok=callback_ok,
        error=string(
            "reason=", result.reason,
            " current_task_id=", previous.task_id,
            " current_job_id=", previous.job_id,
            " current_generation=", previous.generation,
            " worker_error=", error_msg
        )
    )
    return false
end

function task_label(task::ConductorTask)::String
    argn = length(task.args)
    return string(
        "task=", task.task_id,
        " retry=", task.retry_count,
        " call=", task.source, ":", task.module_name, ":", task.function_name,
        " args=", argn,
        " callback=", task.coordinator_ip, ":", task.coordinator_port
    )
end

function probe_node(node::NODES; timeout=DEFAULT_STATUS_TIMEOUT)
    # ネットワーク的に "down" のときは ARP/route/TCP のタイムアウトで数秒〜数十秒待たされることがある。
    # ここでは Conductor 側でタイムアウトを設けて、一定時間で :down とみなす。
    t = @async begin
        return query_server_status(node.IP, node.port)
    end

    w = Base.timedwait(() -> istaskdone(t), timeout; pollint=0.01)
    if w === :timed_out
        return NODE_DOWN
    end

    status = try
        fetch(t)
    catch
        return NODE_DOWN
    end

    if status == "STATUS|idle"
        return NODE_IDLE
    elseif status == "STATUS|busy"
        return NODE_BUSY
    else
        return NODE_DOWN
    end
end

function request_node_cache_clear(node::NODES)::Int
    sock = connect(node.IP, node.port)
    try
        println(sock, add_checksum("CACHE_CLEAR"))
        resp = readline(sock)
        parts = split(chomp(resp), '|')
        if length(parts) == 3 && parts[1] == "CACHE" && parts[2] == "CLEARED"
            cleared = try
                parse(Int, parts[3])
            catch
                throw(ArgumentError("Invalid CACHE_CLEAR count from $(node.IP):$(node.port): $(parts[3])"))
            end
            return max(cleared, 0)
        end
        throw(ArgumentError("Unexpected CACHE_CLEAR response from $(node.IP):$(node.port): $(resp)"))
    finally
        close(sock)
    end
end

function clear_node_cache_with_timeout(node::NODES; timeout=DEFAULT_CACHE_CLEAR_TIMEOUT)
    t = @async begin
        return request_node_cache_clear(node)
    end

    w = Base.timedwait(() -> istaskdone(t), timeout; pollint=0.01)
    if w === :timed_out
        return (ok=false, cleared=0, error="timeout")
    end

    try
        cleared = fetch(t)
        return (ok=true, cleared=cleared, error="")
    catch e
        return (ok=false, cleared=0, error=sprint(showerror, e))
    end
end

function clear_all_node_caches(nodes::Vector{NODES}; timeout=DEFAULT_CACHE_CLEAR_TIMEOUT)
    start_generations = [get_node_runtime_state(node).generation for node in nodes]
    tasks = [@async clear_node_cache_with_timeout(node; timeout=timeout) for node in nodes]

    total_nodes = length(nodes)
    success_nodes = 0
    failed_nodes = 0
    cleared_functions = 0

    for (node, t, start_generation) in zip(nodes, tasks, start_generations)
        result = try
            fetch(t)
        catch e
            (ok=false, cleared=0, error=sprint(showerror, e))
        end

        if result.ok
            success_nodes += 1
            cleared_functions += result.cleared
            observation = probe_node_observation(node; timeout=DEFAULT_STATUS_TIMEOUT)
            apply_node_observation!(observation; source=:cache_status)
            log_conductor_event(
                "CACHE_CLEAR_NODE_OK";
                node_name=node.name,
                node_ip=node.IP,
                node_port=node.port,
                status=string(result.cleared),
                queue_len=queue_len()
            )
        else
            failed_nodes += 1
            observation = NodeObservation(node, NODE_DOWN, start_generation)
            apply_node_observation!(observation; source=:cache_clear)
            log_conductor_event(
                "CACHE_CLEAR_NODE_FAILED";
                node_name=node.name,
                node_ip=node.IP,
                node_port=node.port,
                error=result.error,
                queue_len=queue_len()
            )
        end
    end

    log_conductor_event(
        "CACHE_CLEAR_ALL_SUMMARY";
        status=string(success_nodes, "/", total_nodes),
        error=string("failed=", failed_nodes, " cleared=", cleared_functions),
        queue_len=queue_len()
    )

    return (
        total_nodes=total_nodes,
        success_nodes=success_nodes,
        failed_nodes=failed_nodes,
        cleared_functions=cleared_functions
    )
end

function default_callback_port(ip::AbstractString)::Int
    parts = split(String(ip), ".")
    if length(parts) != 4
        throw(ArgumentError("Invalid IPv4 address: $ip"))
    end
    return 8000 + parse(Int, parts[end])
end

function parse_submit_task(payload::String)::ConductorTask
    parts = split(payload, '|')
    if length(parts) < 3 || parts[1] != "SUBMIT"
        throw(ArgumentError("Invalid SUBMIT format"))
    end

    coordinator_ip = parts[2]
    idx = 3
    coordinator_port = 0
    func_spec = ""

    if occursin(":", parts[idx])
        coordinator_port = default_callback_port(coordinator_ip)
        func_spec = parts[idx]
        idx += 1
    else
        coordinator_port = parse(Int, parts[idx])
        idx += 1
        if length(parts) < idx
            throw(ArgumentError("Missing source:module:function"))
        end
        func_spec = parts[idx]
        idx += 1
    end

    header = split(func_spec, ':')
    if length(header) != 3
        throw(ArgumentError("Invalid function spec: $func_spec"))
    end
    source = header[1]
    module_name = header[2]
    function_name = header[3]
    args = idx <= length(parts) ? parts[idx:end] : String[]

    return ConductorTask(
        string(uuid4()),
        coordinator_ip,
        coordinator_port,
        source,
        module_name,
        function_name,
        args,
        0
    )
end

function queue_len()::Int
    lock(task_queue_lock) do
        return length(task_queue)
    end
end

function enqueue_task!(task::ConductorTask)
    lock(task_queue_lock) do
        push!(task_queue, task)
    end
end

function pop_task!()::Union{Nothing,ConductorTask}
    lock(task_queue_lock) do
        isempty(task_queue) && return nothing
        return pop!(task_queue)  # LIFO
    end
end

function requeue_with_retry!(task::ConductorTask; max_retry=DEFAULT_MAX_RETRY)
    next_retry = task.retry_count + 1
    if next_retry > max_retry
        println("Drop task ", task.task_id, " after retries=", task.retry_count)
        log_task_event("TASK_DROPPED", task; queue_len=queue_len(), error="max_retry_exceeded")
        return
    end

    retried = ConductorTask(
        task.task_id,
        task.coordinator_ip,
        task.coordinator_port,
        task.source,
        task.module_name,
        task.function_name,
        task.args,
        next_retry
    )
    enqueue_task!(retried)
    log_task_event("TASK_REQUEUED", retried; queue_len=queue_len())
end

function default_node_runtime_state()::NodeRuntimeState
    return NodeRuntimeState(NODE_DOWN, UInt64(0), "", "")
end

function get_node_runtime_state(node::NODES)::NodeRuntimeState
    lock(node_states_lock) do
        return get(node_states, (node.IP, node.port), default_node_runtime_state())
    end
end

function get_node_state(node::NODES)::Symbol
    return get_node_runtime_state(node).state
end

function validate_legacy_node_state(state::Symbol)
    state in (NODE_IDLE, NODE_BUSY, NODE_DOWN) && return nothing
    throw(ArgumentError("unsupported node state: $state"))
end

function validate_observed_node_state(state::Symbol)
    state in (NODE_IDLE, NODE_BUSY, NODE_DOWN) && return nothing
    throw(ArgumentError("unsupported observed node state: $state"))
end

function validate_release_node_state(state::Symbol)
    state in (NODE_IDLE, NODE_DOWN) && return nothing
    throw(ArgumentError("unsupported node release state: $state"))
end

function log_node_state_change(node::NODES, prev_state::Symbol, next_state::Symbol)
    prev_state == next_state && return nothing
    log_conductor_event(
        "NODE_STATE_CHANGED";
        node_name=node.name,
        node_ip=node.IP,
        node_port=node.port,
        state_from=string(prev_state),
        state_to=string(next_state),
        queue_len=queue_len()
    )
    return nothing
end

function set_node_state!(node::NODES, state::Symbol)::Nothing
    validate_legacy_node_state(state)
    prev_state = NODE_DOWN
    changed = false
    lock(node_states_lock) do
        key = (node.IP, node.port)
        current = get(node_states, key, default_node_runtime_state())
        prev_state = current.state
        clear_assignment = state == NODE_IDLE || state == NODE_DOWN
        task_id = clear_assignment ? "" : current.task_id
        job_id = clear_assignment ? "" : current.job_id
        node_states[key] = NodeRuntimeState(
            state,
            current.generation + UInt64(1),
            task_id,
            job_id
        )
        changed = current.state != state
    end
    changed && log_node_state_change(node, prev_state, state)
    return nothing
end

function apply_observed_node_state!(
    node::NODES,
    state::Symbol,
    expected_generation::UInt64
)::Bool
    validate_observed_node_state(state)
    prev_state = NODE_DOWN
    applied = false
    state_changed = false
    lock(node_states_lock) do
        key = (node.IP, node.port)
        current = get(node_states, key, default_node_runtime_state())
        prev_state = current.state
        if current.generation == expected_generation && isempty(current.task_id)
            node_states[key] = NodeRuntimeState(
                state,
                current.generation + UInt64(1),
                "",
                ""
            )
            applied = true
            state_changed = current.state != state
        end
    end
    state_changed && log_node_state_change(node, prev_state, state)
    return applied
end

function try_reserve_node!(node::NODES, task_id::String)::Bool
    isempty(task_id) && throw(ArgumentError("task_id must not be empty"))
    reserved = false
    lock(node_states_lock) do
        key = (node.IP, node.port)
        current = get(node_states, key, default_node_runtime_state())
        if current.state == NODE_IDLE && isempty(current.task_id) && isempty(current.job_id)
            node_states[key] = NodeRuntimeState(
                NODE_RESERVED,
                current.generation + UInt64(1),
                task_id,
                ""
            )
            reserved = true
        end
    end
    reserved && log_node_state_change(node, NODE_IDLE, NODE_RESERVED)
    return reserved
end

function mark_node_running!(node::NODES, task_id::String, job_id::String)::Bool
    isempty(task_id) && throw(ArgumentError("task_id must not be empty"))
    isempty(job_id) && throw(ArgumentError("job_id must not be empty"))
    marked = false
    lock(node_states_lock) do
        key = (node.IP, node.port)
        current = get(node_states, key, default_node_runtime_state())
        if current.state == NODE_RESERVED && current.task_id == task_id && isempty(current.job_id)
            node_states[key] = NodeRuntimeState(
                NODE_BUSY,
                current.generation + UInt64(1),
                task_id,
                job_id
            )
            marked = true
        end
    end
    marked && log_node_state_change(node, NODE_RESERVED, NODE_BUSY)
    return marked
end

function release_node_assignment!(
    node::NODES,
    task_id::String,
    job_id::String;
    next_state::Symbol=NODE_IDLE
)::Bool
    validate_release_node_state(next_state)
    released = false
    prev_state = NODE_DOWN
    lock(node_states_lock) do
        key = (node.IP, node.port)
        current = get(node_states, key, default_node_runtime_state())
        prev_state = current.state
        if !isempty(current.task_id) &&
           current.task_id == task_id &&
           current.job_id == job_id
            node_states[key] = NodeRuntimeState(
                next_state,
                current.generation + UInt64(1),
                "",
                ""
            )
            released = true
        end
    end
    released && log_node_state_change(node, prev_state, next_state)
    return released
end

function probe_node_observation(
    node::NODES;
    timeout=DEFAULT_STATUS_TIMEOUT
)::NodeObservation
    snapshot = get_node_runtime_state(node)
    state = try
        probe_node(node; timeout=timeout)
    catch
        NODE_DOWN
    end
    return NodeObservation(node, state, snapshot.generation)
end

function probe_nodes_parallel(
    nodes::Vector{NODES};
    timeout=DEFAULT_STATUS_TIMEOUT
)::Vector{NodeObservation}
    tasks = [@async probe_node_observation(node; timeout=timeout) for node in nodes]
    observations = Vector{NodeObservation}(undef, length(nodes))
    for i in eachindex(tasks)
        observations[i] = fetch(tasks[i])
    end
    return observations
end

function apply_node_observation!(observation::NodeObservation; source::Symbol)::Bool
    applied = apply_observed_node_state!(
        observation.node,
        observation.state,
        observation.expected_generation
    )
    applied && return true

    current = get_node_runtime_state(observation.node)
    reason = current.generation == observation.expected_generation ?
        "active_assignment" : "generation_changed"
    log_conductor_event(
        "NODE_OBSERVATION_IGNORED";
        task_id=current.task_id,
        node_name=observation.node.name,
        node_ip=observation.node.IP,
        node_port=observation.node.port,
        job_id=current.job_id,
        queue_len=queue_len(),
        state_from=string(current.state),
        state_to=string(observation.state),
        status=string(source),
        error=string(
            "reason=", reason,
            " expected_generation=", observation.expected_generation,
            " current_generation=", current.generation
        )
    )
    return false
end

function refresh_states_until_idle!(nodes::Vector{NODES}; timeout=DEFAULT_STATUS_TIMEOUT)::Bool
    # Probe all nodes in parallel to minimize submit-path lag.
    observations = probe_nodes_parallel(nodes; timeout=timeout)
    for observation in observations
        apply_node_observation!(observation; source=:refresh)
    end
    return any(node -> get_node_state(node) == NODE_IDLE, nodes)
end

function pick_idle_node_right_to_left(nodes::Vector{NODES})::Union{Nothing,NODES}
    for node in reverse(nodes)
        if get_node_state(node) == NODE_IDLE
            return node
        end
    end
    return nothing
end

function reserve_idle_node_right_to_left!(
    nodes::Vector{NODES},
    task_id::String
)::Union{Nothing,NODES}
    isempty(task_id) && throw(ArgumentError("task_id must not be empty"))
    selected = nothing
    lock(node_states_lock) do
        for node in reverse(nodes)
            key = (node.IP, node.port)
            current = get(node_states, key, default_node_runtime_state())
            if current.state == NODE_IDLE && isempty(current.task_id) && isempty(current.job_id)
                node_states[key] = NodeRuntimeState(
                    NODE_RESERVED,
                    current.generation + UInt64(1),
                    task_id,
                    ""
                )
                selected = node
                break
            end
        end
    end

    if selected !== nothing
        log_node_state_change(selected, NODE_IDLE, NODE_RESERVED)
        log_conductor_event(
            "NODE_RESERVED";
            task_id=task_id,
            node_name=selected.name,
            node_ip=selected.IP,
            node_port=selected.port,
            queue_len=queue_len(),
            state_from=string(NODE_IDLE),
            state_to=string(NODE_RESERVED)
        )
    end
    return selected
end

function node_reserved_for_task(node::NODES, task_id::String)::Bool
    current = get_node_runtime_state(node)
    return current.state == NODE_RESERVED &&
        current.task_id == task_id &&
        isempty(current.job_id)
end

function idle_node_endpoints()::Vector{String}
    lock(node_states_lock) do
        endpoints = String[]
        for ((ip, port), runtime_state) in node_states
            runtime_state.state == NODE_IDLE || continue
            push!(endpoints, string(ip, ":", port))
        end
        return endpoints
    end
end

function mark_node_busy_after_rejection!(node::NODES, task_id::String)::Bool
    isempty(task_id) && throw(ArgumentError("task_id must not be empty"))
    transitioned = false
    lock(node_states_lock) do
        key = (node.IP, node.port)
        current = get(node_states, key, default_node_runtime_state())
        if current.state == NODE_RESERVED && current.task_id == task_id && isempty(current.job_id)
            node_states[key] = NodeRuntimeState(
                NODE_BUSY,
                current.generation + UInt64(1),
                "",
                ""
            )
            transitioned = true
        end
    end
    transitioned && log_node_state_change(node, NODE_RESERVED, NODE_BUSY)
    return transitioned
end

function dispatch_to_worker(task::ConductorTask, node::NODES)::DispatchOutcome
    node_reserved_for_task(node, task.task_id) || throw(ArgumentError(
        "node $(node.IP):$(node.port) is not reserved for task $(task.task_id)"
    ))
    conductor_ip = string(preferred_local_ip())
    conductor_port_num = conductor_port()
    wire_args = copy(task.args)
    push!(wire_args, "__syncopade_meta_task_id=$(task.task_id)")
    push!(wire_args, "__syncopade_meta_conductor_ip=$(conductor_ip)")
    push!(wire_args, "__syncopade_meta_conductor_port=$(conductor_port_num)")

    client = SyncopadeClient(
        node.IP,
        node.port,
        task.coordinator_ip,
        task.coordinator_port,
        task.source,
        task.module_name,
        task.function_name,
        wire_args
    )

    try
        println("Dispatch start ", task_label(task), " worker=", node.name, "(", node.IP, ":", node.port, ")")
        log_task_event(
            "DISPATCH_START",
            task;
            node_name=node.name,
            node_ip=node.IP,
            node_port=node.port,
            queue_len=queue_len()
        )
        dispatch_task = @async try
            (job_id=syncopade_calc_request(client), error=nothing)
        catch error_value
            (job_id="", error=error_value)
        end
        w = Base.timedwait(() -> istaskdone(dispatch_task), DEFAULT_DISPATCH_TIMEOUT; pollint=0.01)
        if w === :timed_out
            throw(SyncopadeWorkerStartTimeoutError(DEFAULT_DISPATCH_TIMEOUT))
        end
        dispatch_result = fetch(dispatch_task)
        dispatch_result.error === nothing || throw(dispatch_result.error)
        jobId = String(dispatch_result.job_id)
        assignment_recorded = mark_node_running!(node, task.task_id, jobId)
        if !assignment_recorded
            current = get_node_runtime_state(node)
            log_task_event(
                "DISPATCH_ASSIGNMENT_CONFLICT",
                task;
                node_name=node.name,
                node_ip=node.IP,
                node_port=node.port,
                job_id=jobId,
                queue_len=queue_len(),
                state_from=string(current.state),
                state_to=string(NODE_BUSY),
                error=string(
                    "current_generation=", current.generation,
                    " current_task_id=", current.task_id,
                    " current_job_id=", current.job_id
                )
            )
        end
        println("Dispatch OK ", task_label(task), " worker=", node.name, " jobId=", jobId)
        log_task_event(
            "DISPATCH_OK",
            task;
            node_name=node.name,
            node_ip=node.IP,
            node_port=node.port,
            job_id=jobId,
            queue_len=queue_len()
        )
        return DISPATCH_ACCEPTED
    catch e
        error_kind = classify_worker_start_error(e)
        if error_kind == :busy
            transitioned = mark_node_busy_after_rejection!(node, task.task_id)
            if !transitioned
                current = get_node_runtime_state(node)
                log_task_event(
                    "BUSY_RESERVATION_RELEASE_FAILED",
                    task;
                    node_name=node.name,
                    node_ip=node.IP,
                    node_port=node.port,
                    job_id=current.job_id,
                    queue_len=queue_len(),
                    state_from=string(current.state),
                    state_to=string(NODE_BUSY),
                    status=string(error_kind),
                    error=string(
                        "current_generation=", current.generation,
                        " current_task_id=", current.task_id,
                        " worker_error=", sprint(showerror, e)
                    )
                )
            end
            println("Dispatch busy ", task_label(task), " worker=", node.name)
            log_task_event(
                "DISPATCH_BUSY",
                task;
                node_name=node.name,
                node_ip=node.IP,
                node_port=node.port,
                status=string(error_kind),
                error=sprint(showerror, e),
                queue_len=queue_len()
            )
            return DISPATCH_BUSY_REJECTED
        end

        released = release_node_assignment!(
            node,
            task.task_id,
            "";
            next_state=NODE_DOWN
        )
        if !released
            current = get_node_runtime_state(node)
            log_task_event(
                "DISPATCH_RESERVATION_RELEASE_FAILED",
                task;
                node_name=node.name,
                node_ip=node.IP,
                node_port=node.port,
                job_id=current.job_id,
                queue_len=queue_len(),
                state_from=string(current.state),
                state_to=string(NODE_DOWN),
                error=string(
                    "current_generation=", current.generation,
                    " current_task_id=", current.task_id
                )
            )
        end
        println("Dispatch failed ", task_label(task), " worker=", node.name, " error=", e)
        log_task_event(
            "DISPATCH_FAILED",
            task;
            node_name=node.name,
            node_ip=node.IP,
            node_port=node.port,
            status=string(error_kind),
            error=sprint(showerror, e),
            queue_len=queue_len()
        )
        return DISPATCH_FAILED
    end
end

function dispatch_queued_tasks(nodes::Vector{NODES}; max_retry=DEFAULT_MAX_RETRY)
    while true
        task = pop_task!()
        task === nothing && return

        node = reserve_idle_node_right_to_left!(nodes, task.task_id)
        if node === nothing
            # keep LIFO order semantics by putting the latest task back on top
            println("No idle worker. Requeue ", task_label(task))
            enqueue_task!(task)
            log_task_event("NO_IDLE_REQUEUE", task; queue_len=queue_len())
            return
        end

        outcome = dispatch_to_worker(task, node)
        if outcome == DISPATCH_BUSY_REJECTED
            enqueue_task!(task)
            log_task_event("TASK_REQUEUED_BUSY", task; queue_len=queue_len())
            return
        elseif outcome == DISPATCH_FAILED
            requeue_with_retry!(task; max_retry=max_retry)
        elseif outcome == DISPATCH_OUTCOME_UNKNOWN
            throw(ArgumentError("DISPATCH_OUTCOME_UNKNOWN is not handled before Step 8"))
        end
    end
end

function run_dispatch_cycle!(nodes::Vector{NODES}; max_retry=DEFAULT_MAX_RETRY)
    lock(dispatch_lock) do
        dispatch_queued_tasks(nodes; max_retry=max_retry)
    end
end

# 利用可能な可能性のあるノードのリストを返す関数
function geneAvailableNodeList()
    entries = configured_node_entries()
    nodes = NODES[]
    for e in entries
        push!(nodes, NODES(e.ip, e.port, e.name))
    end
    return nodes
end

function conductor_port()
    ip = string(preferred_local_ip())
    parts = split(ip, ".")
    last = parse(Int, parts[end])
    return 9000 + last
end

# Monitor the status of all candidate nodes by polling periodically and printing their state.
function monitor_nodes(; interval=DEFAULT_POLL_INTERVAL, max_retry=DEFAULT_MAX_RETRY)
    nodes = geneAvailableNodeList()
    while true
        println("---- Syncopade Conductor Status @ ", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"), " ----")
        observations = probe_nodes_parallel(nodes; timeout=DEFAULT_STATUS_TIMEOUT)
        for observation in observations
            applied = apply_node_observation!(observation; source=:monitor)
            node = observation.node
            current_state = get_node_state(node)
            suffix = applied ? "" : string(" (observed=", observation.state, " ignored)")
            println(rpad(node.name,10)," ", node.IP, ":", node.port, " => ", current_state, suffix)
        end
        run_dispatch_cycle!(nodes; max_retry=max_retry)
        println("queue length => ", queue_len())
        println()
        sleep(interval)
    end
end

# Conductor server commands (checksum required):
# - LIST
# - SUBMIT|coordinator_ip|coordinator_port(optional)|source:module:function|arg1|arg2|...
# - DONE|task_id|job_id|worker_ip|worker_port|status|started_at|finished_at|callback_ok|error_message
# - CACHE_CLEAR_ALL
function conductor_server()
    bind_ip = preferred_local_ip()
    port = conductor_port()
    server = listen(bind_ip, port)
    println("Conductor server listening on ", string(bind_ip), ":", port)
    log_conductor_event("CONDUCTOR_START"; node_name="conductor", node_ip=string(bind_ip), node_port=port)

    @async while true
        sock = accept(server)
        @async begin
            try
                msg = String(strip(readline(sock)))
                ok, payload = verify_checksum(msg)
                if !ok
                    println(sock, add_checksum("ERROR|BAD_CHECKSUM"))
                else
                    parts = split(payload, '|')
                    cmd = parts[1]

                    if cmd == "LIST"
                        idle_nodes = idle_node_endpoints()
                        println(sock, add_checksum("NODES|" * join(idle_nodes, "|")))
                    elseif cmd == "SUBMIT"
                        println("SUBMIT payload = ", payload)
                        task = parse_submit_task(payload)
                        enqueue_task!(task)
                        qlen = queue_len()
                        println("Queued ", task_label(task), " queue_len=", qlen)
                        log_task_event("TASK_QUEUED", task; queue_len=qlen)
                        println(sock, add_checksum("OK|QUEUED|" * task.task_id))

                        # Fast path: try dispatch immediately after enqueue
                        # so we don't wait for the next monitor cycle.
                        @async begin
                            nodes = geneAvailableNodeList()
                            refresh_states_until_idle!(nodes; timeout=DEFAULT_STATUS_TIMEOUT)
                            run_dispatch_cycle!(nodes; max_retry=DEFAULT_MAX_RETRY)
                        end
                    elseif cmd == "DONE"
                        handle_done_payload(payload)
                        println(sock, add_checksum("OK|DONE_ACK"))
                    elseif cmd == "CACHE_CLEAR_ALL"
                        nodes = geneAvailableNodeList()
                        summary = clear_all_node_caches(nodes; timeout=DEFAULT_CACHE_CLEAR_TIMEOUT)
                        resp_payload = join(
                            String[
                                "OK",
                                "CACHE_CLEAR_ALL",
                                string(summary.total_nodes),
                                string(summary.success_nodes),
                                string(summary.failed_nodes),
                                string(summary.cleared_functions)
                            ],
                            "|"
                        )
                        println(sock, add_checksum(resp_payload))
                    else
                        println(sock, add_checksum("ERROR|UNKNOWN_COMMAND"))
                    end
                end
            catch e
                println("Conductor server error: ", e)
                try
                    println(sock, add_checksum("ERROR|SERVER_ERROR"))
                catch
                end
            finally
                close(sock)
            end
        end
    end
end

function main()
    conductor_server()
    monitor_nodes(interval=1.0)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
