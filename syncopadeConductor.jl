include("syncopadeClient.jl")
using Dates

struct NODES
    IP::String
    port::Int
end

const NODE_IDLE = :idle
const NODE_BUSY = :busy
const NODE_DOWN = :down

const DEFAULT_POLL_INTERVAL = 2.0  # seconds
const DEFAULT_STATUS_TIMEOUT = 1.0  # seconds (per node)

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

# 利用可能な可能性のあるノードのリストを返す関数
function geneAvailableNodeList()
    nodes = NODES[] 
    push!(nodes, NODES("192.168.100.26", 8026)) # C-3PX - Phyduck
    push!(nodes, NODES("192.168.100.30", 8030)) # Chopper
    push!(nodes, NODES("192.168.100.5", 8105))  # dammy for test    

    return nodes        
end

# Monitor the status of all candidate nodes by polling periodically and printing their state.
function monitor_nodes(; interval=DEFAULT_POLL_INTERVAL)
    nodes = geneAvailableNodeList()
    while true
        println("---- Syncopade Conductor Status @ ", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"), " ----")
        for node in nodes
            state = probe_node(node)
            println(" ", node.IP, ":", node.port, " => ", state)
        end
        println()
        sleep(interval)
    end
end
