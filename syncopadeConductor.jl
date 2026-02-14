include("syncopadeClient.jl")
using Dates
using Sockets
using UUIDs

# shared state for conductor
const node_states = Dict{Tuple{String,Int},Symbol}()
const node_states_lock = ReentrantLock()
const task_queue_lock = ReentrantLock()

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
const DEFAULT_STATUS_TIMEOUT = 1.0  # seconds (per node)
const DEFAULT_MAX_RETRY = 3

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
end

function get_node_state(node::NODES)::Symbol
    lock(node_states_lock) do
        return get(node_states, (node.IP, node.port), NODE_DOWN)
    end
end

function set_node_state!(node::NODES, state::Symbol)
    lock(node_states_lock) do
        node_states[(node.IP, node.port)] = state
    end
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
    client = SyncopadeClient(
        node.IP,
        node.port,
        task.coordinator_ip,
        task.coordinator_port,
        task.source,
        task.module_name,
        task.function_name,
        task.args
    )

    try
        jobId = syncopade_calc_request(client)
        set_node_state!(node, NODE_BUSY)
        println("Dispatch OK task=", task.task_id, " worker=", node.name, " jobId=", jobId)
        return true
    catch e
        set_node_state!(node, NODE_DOWN)
        println("Dispatch failed task=", task.task_id, " worker=", node.name, " error=", e)
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
            enqueue_task!(task)
            return
        end

        ok = dispatch_to_worker(task, node)
        if !ok
            requeue_with_retry!(task; max_retry=max_retry)
        end
    end
end

# 利用可能な可能性のあるノードのリストを返す関数
function geneAvailableNodeList()
    nodes = NODES[] 
    push!(nodes, NODES("192.168.100.26", 8026, "C-3PX"))
    push!(nodes, NODES("192.168.100.30", 8030, "Chopper"))
    push!(nodes, NODES("192.168.100.37", 8037, "BD-1"))
    push!(nodes, NODES("192.168.100.38", 8038, "GNK_EG-6"))
    push!(nodes, NODES("192.168.100.48", 8048, "GONKY"))
    push!(nodes, NODES("192.168.100.73", 8073, "Hunter"))
    push!(nodes, NODES("192.168.100.74", 8074, "Tech"))
    push!(nodes, NODES("192.168.100.75", 8075, "Crosshair"))
    push!(nodes, NODES("192.168.100.76", 8076, "Wrecker"))
    push!(nodes, NODES("192.168.100.77", 8077, "Echo"))
    push!(nodes, NODES("192.168.100.78", 8078, "Omega"))
    push!(nodes, NODES("192.168.100.95", 8095, "D-O"))

    return nodes        
end

function conductor_port()
    ip = string(getipaddr())
    parts = split(ip, ".")
    last = parse(Int, parts[end])
    return 9000 + last
end

# Monitor the status of all candidate nodes by polling periodically and printing their state.
function monitor_nodes(; interval=DEFAULT_POLL_INTERVAL, max_retry=DEFAULT_MAX_RETRY)
    nodes = geneAvailableNodeList()
    while true
        println("---- Syncopade Conductor Status @ ", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"), " ----")
        for node in nodes
            state = probe_node(node)
            set_node_state!(node, state)
            println(rpad(node.name,10)," ", node.IP, ":", node.port, " => ", state)
        end
        dispatch_queued_tasks(nodes; max_retry=max_retry)
        println("queue length => ", queue_len())
        println()
        sleep(interval)
    end
end

# Conductor server commands (checksum required):
# - LIST
# - SUBMIT|coordinator_ip|coordinator_port(optional)|source:module:function|arg1|arg2|...
function conductor_server()
    port = conductor_port()
    server = listen(getipaddr(), port)
    println("Conductor server listening on ", string(getipaddr()), ":", port)

    @async while true
        sock = accept(server)
        @async begin
            try
                msg = strip(readline(sock))
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
                        task = parse_submit_task(payload)
                        enqueue_task!(task)
                        println("Queued task=", task.task_id, " retry=", task.retry_count, " queue_len=", queue_len())
                        println(sock, add_checksum("OK|QUEUED|" * task.task_id))
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