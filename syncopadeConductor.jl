include("syncopadeClient.jl")
include("syncopadeNodeConfig.jl")
using Dates
using Sockets
using UUIDs

# shared state for conductor
const node_states = Dict{Tuple{String,Int},Symbol}()
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

const task_queue = ConductorTask[]

const NODE_IDLE = :idle
const NODE_BUSY = :busy
const NODE_DOWN = :down

const DEFAULT_POLL_INTERVAL = 2.0  # seconds
const DEFAULT_STATUS_TIMEOUT = 0.2  # seconds (per node)
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

function handle_done_payload(payload::String)
    parts = split(payload, '|')
    if length(parts) < 10 || parts[1] != "DONE"
        throw(ArgumentError("Invalid DONE format"))
    end

    task_id = parts[2]
    job_id = parts[3]
    worker_ip = parts[4]
    worker_port = parse(Int, parts[5])
    status = parts[6]
    started_at = parts[7]
    finished_at = parts[8]
    callback_ok = parts[9]
    error_msg = join(parts[10:end], "|")

    node = find_node_by_endpoint(worker_ip, worker_port)
    set_node_state!(node, NODE_IDLE)
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

function get_node_state(node::NODES)::Symbol
    lock(node_states_lock) do
        return get(node_states, (node.IP, node.port), NODE_DOWN)
    end
end

function set_node_state!(node::NODES, state::Symbol)
    prev_state = NODE_DOWN
    changed = false
    lock(node_states_lock) do
        prev_state = get(node_states, (node.IP, node.port), NODE_DOWN)
        node_states[(node.IP, node.port)] = state
        changed = prev_state != state
    end
    if changed
        log_conductor_event(
            "NODE_STATE_CHANGED";
            node_name=node.name,
            node_ip=node.IP,
            node_port=node.port,
            state_from=string(prev_state),
            state_to=string(state),
            queue_len=queue_len()
        )
    end
end

function probe_nodes_parallel(nodes::Vector{NODES}; timeout=DEFAULT_STATUS_TIMEOUT)::Vector{Symbol}
    tasks = [@async probe_node(node; timeout=timeout) for node in nodes]
    states = Vector{Symbol}(undef, length(nodes))
    for i in eachindex(tasks)
        states[i] = try
            fetch(tasks[i])
        catch
            NODE_DOWN
        end
    end
    return states
end

function refresh_states_until_idle!(nodes::Vector{NODES}; timeout=DEFAULT_STATUS_TIMEOUT)::Bool
    # Probe all nodes in parallel to minimize submit-path lag.
    states = probe_nodes_parallel(nodes; timeout=timeout)
    any_idle = false
    for (node, state) in zip(nodes, states)
        set_node_state!(node, state)
        any_idle = any_idle || (state == NODE_IDLE)
    end
    return any_idle
end

function pick_idle_node_right_to_left(nodes::Vector{NODES})::Union{Nothing,NODES}
    for node in reverse(nodes)
        if get_node_state(node) == NODE_IDLE
            return node
        end
    end
    return nothing
end

function dispatch_to_worker(task::ConductorTask, node::NODES)::Bool
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
        dispatch_task = @async syncopade_calc_request(client)
        w = Base.timedwait(() -> istaskdone(dispatch_task), DEFAULT_DISPATCH_TIMEOUT; pollint=0.01)
        if w === :timed_out
            throw(ArgumentError("dispatch timeout waiting worker start-ack > $(DEFAULT_DISPATCH_TIMEOUT)s"))
        end
        jobId = fetch(dispatch_task)
        set_node_state!(node, NODE_BUSY)
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
        return true
    catch e
        set_node_state!(node, NODE_DOWN)
        println("Dispatch failed ", task_label(task), " worker=", node.name, " error=", e)
        log_task_event(
            "DISPATCH_FAILED",
            task;
            node_name=node.name,
            node_ip=node.IP,
            node_port=node.port,
            error=sprint(showerror, e),
            queue_len=queue_len()
        )
        return false
    end
end

function dispatch_queued_tasks(nodes::Vector{NODES}; max_retry=DEFAULT_MAX_RETRY)
    while true
        task = pop_task!()
        task === nothing && return

        node = pick_idle_node_right_to_left(nodes)
        if node === nothing
            # keep LIFO order semantics by putting the latest task back on top
            println("No idle worker. Requeue ", task_label(task))
            enqueue_task!(task)
            log_task_event("NO_IDLE_REQUEUE", task; queue_len=queue_len())
            return
        end

        ok = dispatch_to_worker(task, node)
        if !ok
            requeue_with_retry!(task; max_retry=max_retry)
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
        states = probe_nodes_parallel(nodes; timeout=DEFAULT_STATUS_TIMEOUT)
        for (node, state) in zip(nodes, states)
            set_node_state!(node, state)
            println(rpad(node.name,10)," ", node.IP, ":", node.port, " => ", state)
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
                        idle_nodes = String[]
                        lock(node_states_lock) do
                            for ((ip, p), state) in node_states
                                if state == NODE_IDLE
                                    push!(idle_nodes, string(ip, ":", p))
                                end
                            end
                        end
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

main()
