using Sockets
using UUIDs

# syncopade job request and callback endpoint struct
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

# checksum utilities
function geneXORchecksum(s::String)
    c = UInt8(0)
    for b in codeunits(s)
        c ⊻= b
    end
    return c
end

function checksum_hex(payload::String)::String
    c = geneXORchecksum(payload)
    return lowercase(string(c, base=16, pad=2))
end

function add_checksum(payload::String)::String
    return payload * "|" * checksum_hex(payload)
end

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

# syncopade_serverに接続するためのクライアントのコード（非同期コールバック対応）
function syncopade_calc_request(pList::SyncopadeClient)
    sock = connect(pList.server_ip_addr, pList.server_port)

    # フォーマットは self_ip_addr|self_port|file:module:func|arg1|arg2|...
    func_spec = string(pList.file_name, ":", pList.module_name, ":", pList.function_name)
    payload_parts = [pList.self_ip_addr, string(pList.self_port), func_spec]
    if !isempty(pList.args)
        append!(payload_parts, pList.args)
    end
    payload = join(payload_parts, "|")
    msg_with_checksum = add_checksum(payload)
    println(sock, msg_with_checksum)

    # 1行だけ読み込み、OK|STARTED|jobIdを受け取る
    resp = readline(sock)
    close(sock)

    # parse response: OK|STARTED|jobId
    resp_parts = split(resp, '|')
    if length(resp_parts) == 3 && resp_parts[1] == "OK" && resp_parts[2] == "STARTED"
        jobId = resp_parts[3]
        return jobId
    else
        error("Unexpected response from server: $resp")
    end
end

function syncopade_result_server(port::Int, handler::Function)
    bind_ip = getipaddr()
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
                parts = split(payload, '|')
                # expected format:
                # RESULT|jobId|OK|value
                # or
                # RESULT|jobId|ERROR|errType|errMsg
                if length(parts) >= 4 && parts[1] == "RESULT"
                    jobId = parts[2]
                    status = parts[3]
                    if status == "OK"
                        value = join(parts[4:end], "|")
                        handler(jobId, true, value)
                    elseif status == "ERROR" && length(parts) >= 5
                        errType = parts[4]
                        errMsg = join(parts[5:end], "|")
                        handler(jobId, false, errType * "|" * errMsg)
                    end
                end
            catch e
                # ignore errors in handler
            end
            close(sock)
        end
    end
end

# one-shot result server:
# listens once, receives exactly one RESULT message, then shuts down
function syncopade_result_server_once(port::Int, handler::Function)
    bind_ip = getipaddr()
    server = listen(bind_ip, port)
    println("one-shot result server bind address: ", bind_ip, ":", port)
    @async begin
        try
            sock = accept(server)
            try
                line = readline(sock)
                ok, payload = verify_checksum(line)
                if ok
                    parts = split(payload, '|')
                    # expected format:
                    # RESULT|jobId|OK|value
                    # or
                    # RESULT|jobId|ERROR|errType|errMsg
                    if length(parts) >= 4 && parts[1] == "RESULT"
                        jobId = parts[2]
                        status = parts[3]
                        if status == "OK"
                            value = join(parts[4:end], "|")
                            handler(jobId, true, value)
                        elseif status == "ERROR" && length(parts) >= 5
                            errType = parts[4]
                            errMsg = join(parts[5:end], "|")
                            handler(jobId, false, errType * "|" * errMsg)
                        end
                    end
                end
            finally
                close(sock)
            end
        finally
            close(server)
        end
    end
end

function query_server_status(server_ip::String, server_port::Int)
    sock = connect(server_ip, server_port)
    payload = "STATUS"
    msg = payload * "|" * checksum_hex(payload)
    println(sock, msg)
    resp = readline(sock)
    close(sock)
    return resp
end

#
# --- Conductor query helpers (ADD ONLY) ---
#
# Query Syncopade Conductor for available nodes
# Protocol:
#   Client -> Conductor : "LIST"
#   Conductor -> Client : "NODES|ip:port|ip:port|..."

function query_conductor_nodes(conductor_ip::String; conductor_port::Int=9000)
    sock = connect(conductor_ip, conductor_port)
    println(sock, "LIST")
    resp = readline(sock)
    close(sock)
    return resp
end

# positional-arg overload for convenience
function query_conductor_nodes(conductor_ip::String, conductor_port::Int)
    return query_conductor_nodes(conductor_ip; conductor_port=conductor_port)
end

# Parse conductor response into Vector{Tuple{String,Int}}
function parse_conductor_nodes(resp::String)
    parts = split(resp, '|')
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

    return nodes
end

# positional-arg overload for convenience
function show_available_nodes(conductor_ip::String, conductor_port::Int)
    return show_available_nodes(conductor_ip; conductor_port=conductor_port)
end

