using Sockets
using UUIDs
using Dates
include("syncopadeNodeConfig.jl")

const server_state = Ref(:idle)  # :idle or :busy
const DEFAULT_UNIX_MOUNT_ROOT = "/Volumes/syncopade_nfs"
const DEFAULT_WINDOWS_MOUNT_ROOT = raw"\\192.168.100.96\syncopade_nfs"
const META_TASK_ID_PREFIX = "__syncopade_meta_task_id="
const META_CONDUCTOR_IP_PREFIX = "__syncopade_meta_conductor_ip="
const META_CONDUCTOR_PORT_PREFIX = "__syncopade_meta_conductor_port="

function configured_mount_root()::String
    if Sys.iswindows()
        return get(ENV, "SYNCOPADE_MOUNT_ROOT_WINDOWS", DEFAULT_WINDOWS_MOUNT_ROOT)
    end
    return get(ENV, "SYNCOPADE_MOUNT_ROOT_UNIX", DEFAULT_UNIX_MOUNT_ROOT)
end

function path_norm_compare(path::String)::String
    p = normpath(path)
    p = replace(p, '\\' => '/')
    return Sys.iswindows() ? lowercase(p) : p
end

function is_under_root(path::String, root::String)::Bool
    path_cmp = path_norm_compare(path)
    root_cmp = path_norm_compare(root)
    return path_cmp == root_cmp || startswith(path_cmp, root_cmp * "/")
end

function ensure_jl_extension(path::AbstractString)::String
    p = String(path)
    return endswith(lowercase(p), ".jl") ? p : p * ".jl"
end

function source_basename(path::AbstractString)::String
    normalized = replace(path, '\\' => '/')
    parts = split(normalized, '/')
    return isempty(parts) ? String(path) : String(parts[end])
end

function resolve_source_script_path(file_name::String, mount_root::String)::String
    source = strip(file_name)
    isempty(source) && throw(ArgumentError("Empty source file name"))

    has_sep = occursin('/', source) || occursin('\\', source)
    candidates = String[]
    if has_sep
        push!(candidates, ensure_jl_extension(source))
        push!(candidates, ensure_jl_extension(joinpath(mount_root, source_basename(source))))
    else
        push!(candidates, ensure_jl_extension(joinpath(mount_root, source)))
        push!(candidates, ensure_jl_extension(source))
    end

    for script_path in unique(candidates)
        if is_under_root(script_path, mount_root) && !isdir(mount_root)
            throw(ArgumentError("Required mount is missing: $(mount_root)"))
        end
        if isfile(script_path)
            return script_path
        end
    end

    throw(ArgumentError("Source script not found. requested=$(file_name) candidates=$(join(candidates, ", "))"))
end


# 以下関数群 ############################################################

function default_server_port_from_ip(ip::IPAddr)::Int
    parts = split(string(ip), '.')
    if length(parts) == 4
        last_octet = tryparse(Int, parts[end])
        if last_octet !== nothing
            return last_octet + 8000
        end
    end
    return 8000
end

function is_bindable_local_ip(ip::AbstractString)::Bool
    test_server = nothing
    try
        test_server = listen(IPv4(ip), 0)
        return true
    catch
        return false
    finally
        if test_server !== nothing
            close(test_server)
        end
    end
end

function resolve_server_bind_target(; requested_port::Union{Nothing,Int}=nothing)
    entries = configured_node_entries()

    for e in entries
        if requested_port !== nothing && e.port != requested_port
            continue
        end
        if is_bindable_local_ip(e.ip)
            return (ip=IPv4(e.ip), port=e.port, source="profile:" * configured_node_profile(), node=e.name)
        end
    end

    fallback_ip = getipaddr()
    fallback_port = requested_port === nothing ? default_server_port_from_ip(fallback_ip) : requested_port
    return (ip=fallback_ip, port=fallback_port, source="fallback:getipaddr", node="unknown")
end

# NOTE: getipaddr() は IPv4/IPv6 オブジェクトを返すため、string() に変換してから split する
# syncopade_serverのラッパー関数
# 引数がないバージョン．指定しないとIPアドレスの最下位の数字＋8000がポートになる
function syncopade_server()
    target = resolve_server_bind_target()
    println("Starting syncopade server on port ", target.port, " ... ")
    println("server bind IP address: ", string(target.ip))
    println("server bind source: ", target.source, " node=", target.node)
    syncopade_server(target.ip, target.port)
end


# syncopadeクライアントからのデータを受信する
# メッセージのフォーマットは
# clientIP|clientPort|file:module:func|arg1|arg2|...|CHECKSUM
# NOTE: arg fields may include internal metadata keys:
#   __syncopade_meta_task_id=
#   __syncopade_meta_conductor_ip=
#   __syncopade_meta_conductor_port=
# CHECKSUMはpayload（最後の|より前の全て）に対するXORチェックサム（16進）
# 即時応答は OK|STARTED|jobId でソケットはすぐ閉じる
# 計算終了後，computeサーバーはclientIP:clientPortに接続し，
# RESULT|jobId|OK|<string(result)>|CHECKSUM
# またはエラー時は
# RESULT|jobId|ERROR|<errorType>|<errorMessage>|CHECKSUM
# を送信する
function syncopade_server(port::Int)
    target = resolve_server_bind_target(requested_port=port)
    syncopade_server(target.ip, port)
end

function syncopade_server(bind_ip::IPAddr, port::Int)
    server = listen(bind_ip, port)
    println("bind address: ", bind_ip, ":", port)
    
    @async begin
        while true
            # クライアントからの接続を待つ
            sock = accept(server)
            @async begin
                try
                    # クライアントからのメッセージを受信
                    row_msg = readline(sock)
                    # チェックサムを検証
                    ok, msg = checksum(row_msg)
                    # チェックサムエラーならばソケットを閉じて次へ
                    if !ok
                        println("Checksum error!")
                        close(sock)
                        return
                    end

                    # Check for STATUS command
                    if msg == "STATUS"
                        println(sock, "STATUS|" * string(server_state[]))
                        close(sock)
                        return
                    end

                    # メッセージを解析してジョブ情報を得る
                    job = convMSG2JOB(msg)

                    # ジョブIDを生成
                    jobId = string(uuid4())

                    # 即時応答を返しソケットを閉じる
                    println(sock, "OK|STARTED|" * jobId)
                    close(sock)

                    # Set server state to busy
                    server_state[] = :busy

                    # 非同期で計算を実行し，コールバックを送信
                    @async begin
                        started_at = Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS.sss")
                        finished_at = started_at
                        exec_status = "ERROR"
                        callback_ok = false
                        error_message = ""
                        try
                            result = call_func(job.file_name, job.module_name, job.function_name, job.args)
                            exec_status = "OK"
                            callback_ok = send_result(job, jobId, true; result=string(result))
                        catch e
                            errType = if e isa LoadError
                                "LOAD_ERROR"
                            elseif e isa UndefVarError
                                "NAME_ERROR"
                            elseif e isa MethodError
                                "METHOD_ERROR"
                            elseif e isa ArgumentError
                                "ARG_ERROR"
                            else
                                "RUNTIME_ERROR"
                            end
                            errMsg = sprint(showerror, e)
                            error_message = errType * "|" * errMsg
                            callback_ok = send_result(job, jobId, false; errType=errType, errMsg=errMsg)
                        finally
                            finished_at = Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS.sss")
                            send_done_notification(
                                job,
                                jobId,
                                string(bind_ip),
                                port;
                                status=exec_status,
                                started_at=started_at,
                                finished_at=finished_at,
                                callback_ok=callback_ok,
                                error_message=error_message
                            )
                            server_state[] = :idle
                        end
                    end
                catch e
                    # 受信処理での致命的エラーはログ出力して終了
                    println("Error handling connection: ", e)
                    try
                        close(sock)
                    catch
                    end
                end
            end
        end
    end    
end

# 受け取ったメッセージの生データをもらって，
# 最後の | 区切り要素をチェックサム（16進）として検証する
# 成功したら true + payload（チェックサムを除いた文字列）を返す
function checksum(msg::String)
    parts = split(chomp(msg), '|')
    if length(parts) < 2
        return false, ""
    end

    payload = join(parts[1:end-1], '|')

    recv_checksum = try
        parse(UInt8, parts[end], base=16)
    catch
        return false, ""
    end

    calc_checksum = geneXORchecksum(payload)

    if recv_checksum == calc_checksum
        return true, payload
    else
        return false, ""
    end
end

# チェックサムを計算する関数
function geneXORchecksum(s::String)
    c = UInt8(0)
    for b in codeunits(s)
        c ⊻= b
    end
    return c
end

# 新しいジョブ情報を保持する構造体
struct SyncopadeJob
    client_ip_addr::String
    client_port::Int
    file_name::String
    module_name::String
    function_name::String
    args::Vector{String}
    task_id::String
    conductor_ip_addr::String
    conductor_port::Int
end

function split_args_and_meta(args::AbstractVector{<:AbstractString})
    user_args = String[]
    task_id = ""
    conductor_ip_addr = ""
    conductor_port = 0

    for a in args
        arg = String(a)
        if startswith(arg, META_TASK_ID_PREFIX)
            task_id = arg[length(META_TASK_ID_PREFIX)+1:end]
        elseif startswith(arg, META_CONDUCTOR_IP_PREFIX)
            conductor_ip_addr = arg[length(META_CONDUCTOR_IP_PREFIX)+1:end]
        elseif startswith(arg, META_CONDUCTOR_PORT_PREFIX)
            p = tryparse(Int, arg[length(META_CONDUCTOR_PORT_PREFIX)+1:end])
            if p !== nothing
                conductor_port = p
            end
        else
            push!(user_args, arg)
        end
    end

    return (
        args=user_args,
        task_id=task_id,
        conductor_ip_addr=conductor_ip_addr,
        conductor_port=conductor_port
    )
end

# payloadのフォーマット:
# clientIP|clientPort|file:module:func|arg1|arg2|...
# ここに渡されるmsgはチェックサムを除いたpayload文字列
function convMSG2JOB(msg::String)::SyncopadeJob
    parts = split(chomp(msg), '|')
    if length(parts) < 3
        throw(ArgumentError("Invalid message format, need at least clientIP, clientPort, header: $msg"))
    end

    client_ip_addr = parts[1]

    client_port = try
        parse(Int, parts[2])
    catch
        throw(ArgumentError("Invalid clientPort: $(parts[2])"))
    end

    header = parts[3]
    header_parts = split(header, ':')
    if length(header_parts) != 3
        throw(ArgumentError("Invalid command header: $header"))
    end

    file_name = header_parts[1]
    module_name = header_parts[2]
    function_name = header_parts[3]

    raw_args = length(parts) > 3 ? parts[4:end] : String[]
    parsed = split_args_and_meta(raw_args)

    return SyncopadeJob(
        client_ip_addr,
        client_port,
        file_name,
        module_name,
        function_name,
        parsed.args,
        parsed.task_id,
        parsed.conductor_ip_addr,
        parsed.conductor_port
    )
end

# フィールド配列をpayload文字列に変換する
function build_payload(fields::Vector{String})::String
    return join(fields, '|')
end

# payload文字列に対する16進チェックサム文字列（2桁小文字）
function checksum_hex(payload::String)::String
    c = geneXORchecksum(payload)
    return lowercase(string(c, base=16, pad=2))
end

# 計算結果またはエラーをクライアントにコールバック送信する
function send_result(job::SyncopadeJob, jobId::String, ok::Bool; result::String="", errType::String="", errMsg::String="")::Bool
    fields = String[]
    push!(fields, "RESULT")
    push!(fields, jobId)
    if ok
        push!(fields, "OK")
        push!(fields, result)
    else
        push!(fields, "ERROR")
        push!(fields, errType)
        push!(fields, errMsg)
    end
    payload = build_payload(fields)
    chksum = checksum_hex(payload)
    msg = payload * "|" * chksum

    try
        sock = connect(job.client_ip_addr, job.client_port)
        println(sock, msg)
        close(sock)
        return true
    catch e
        println("Failed to send callback to $(job.client_ip_addr):$(job.client_port): ", e)
        return false
    end
end

function send_done_notification(
    job::SyncopadeJob,
    jobId::String,
    worker_ip_addr::String,
    worker_port::Int;
    status::String,
    started_at::String,
    finished_at::String,
    callback_ok::Bool,
    error_message::String=""
)::Bool
    if isempty(job.task_id) || isempty(job.conductor_ip_addr) || job.conductor_port <= 0
        return false
    end

    fields = String[
        "DONE",
        job.task_id,
        jobId,
        worker_ip_addr,
        string(worker_port),
        status,
        started_at,
        finished_at,
        callback_ok ? "true" : "false",
        error_message
    ]
    payload = build_payload(fields)
    msg = payload * "|" * checksum_hex(payload)

    try
        sock = connect(job.conductor_ip_addr, job.conductor_port)
        println(sock, msg)
        ack = readline(sock)
        close(sock)
        ack_ok, _ = checksum(ack)
        return ack_ok
    catch e
        println("Failed to send DONE to conductor $(job.conductor_ip_addr):$(job.conductor_port): ", e)
        return false
    end
end

# リモートから指定されたプログラムファイルを開いて関数を実行する
# args はすべて String として渡される
# 型変換は呼び出される関数側で行う
# 呼び出しの戻り値はそのまま返される．Stringを返すこと
function call_func(file_name::String, module_name::String, func_name::String, args::Vector{String}=String[])
    required_mount_root = configured_mount_root()
    script_path = resolve_source_script_path(file_name, required_mount_root)

    include(script_path)

    mod = Base.invokelatest(getfield, Main, Symbol(module_name))
    f   = Base.invokelatest(getfield, mod,  Symbol(func_name))

    return Base.invokelatest(f, args...) 
end


# ---------------------------------------------------------------------
# Runnable entrypoint
# ---------------------------------------------------------------------
function main()
    syncopade_server()
    println("Syncopade server is running. Type 'q' + Enter to quit.")
    while true
        if eof(stdin)
            break
        end
        cmd = strip(readline(stdin))
        lowercase(cmd) == "q" && break
    end
end

main()
