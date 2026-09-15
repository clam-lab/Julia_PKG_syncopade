using Sockets
using UUIDs
using Dates
include("syncopadeNodeConfig.jl")
include("syncopadeExecutor.jl")
include("syncopadeServerRuntime.jl")

const server_state = Ref(:idle)  # :idle or :busy
const server_state_lock = ReentrantLock()
const META_TASK_ID_PREFIX = "__syncopade_meta_task_id="
const META_CONDUCTOR_IP_PREFIX = "__syncopade_meta_conductor_ip="
const META_CONDUCTOR_PORT_PREFIX = "__syncopade_meta_conductor_port="

function get_server_state()::Symbol
    lock(server_state_lock) do
        return server_state[]
    end
end

function try_reserve_server!()::Bool
    lock(server_state_lock) do
        server_state[] == :idle || return false
        server_state[] = :busy
        return true
    end
end

function release_server!()::Nothing
    lock(server_state_lock) do
        server_state[] = :idle
    end
    return nothing
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
# server busy時は ERROR|BUSY を返し、job IDを発行しない
# 制御コマンド:
# STATUS|checksum      -> STATUS|<idle|busy>
# CACHE_CLEAR|checksum -> CACHE|CLEARED|<count>
# 計算終了後，computeサーバーはclientIP:clientPortに接続し，
# RESULT|jobId|OK|<string(result)>|CHECKSUM
# またはエラー時は
# RESULT|jobId|ERROR|<errorType>|<errorMessage>|CHECKSUM
# conductor metadata付きjobでは
# TASK_RESULT|taskId|jobId|OK|<string(result)>|CHECKSUM
# または
# TASK_RESULT|taskId|jobId|ERROR|<errorType>|<errorMessage>|CHECKSUM
# を送信する
function syncopade_server(port::Int)
    target = resolve_server_bind_target(requested_port=port)
    syncopade_server(target.ip, port)
end

mutable struct ListenerHandle
    socket::Sockets.TCPServer
    bind_ip::IPAddr
    port::Int
    supervisor::ExecutorSupervisor
    accept_task::Union{Nothing,Task}
    startup_task::Union{Nothing,Task}
    job_task::Union{Nothing,Task}
    connections::Dict{TCPSocket,Task}
end

function syncopade_server(bind_ip::IPAddr, port::Int;
    config=ExecutorLaunchConfig(), audit=stdout, output=stdout, errors=stderr)
    server = listen(bind_ip, port)
    actual_port = Int(getsockname(server)[2])
    supervisor = ExecutorSupervisor(ServerRuntime(); config, audit, output, errors)
    handle = ListenerHandle(server, bind_ip, actual_port, supervisor, nothing, nothing, nothing, Dict{TCPSocket,Task}())
    println(output, "bind address: ", bind_ip, ":", actual_port)
    handle.startup_task = @async launch_executor!(supervisor)
    handle.accept_task = @async begin
        while isopen(server)
            socket = try
                accept(server)
            catch
                isopen(server) && rethrow()
                break
            end
            handle.connections[socket] = @async try
                handle_server_connection!(handle, socket)
            finally
                close(socket)
                delete!(handle.connections, socket)
            end
        end
    end
    return handle
end

function handle_server_connection!(handle::ListenerHandle, socket::TCPSocket)
    supervisor = handle.supervisor
    runtime = supervisor.runtime
    reservation = nothing
    try
        valid, message = checksum(readline(socket))
        valid || return nothing
        if message == "STATUS"
            println(socket, "STATUS|" * string(runtime_public_state(runtime)))
            return nothing
        elseif message == "CACHE_CLEAR"
            println(socket, "ERROR|CACHE_CLEAR_UNAVAILABLE")
            return nothing
        end
        job = convMSG2JOB(message)
        job_id = string(uuid4())
        reservation = runtime_reserve_job!(runtime, job_id)
        if reservation === nothing
            println(socket, "ERROR|BUSY")
            return nothing
        end
        executor_audit(supervisor, "job_reserved", reservation; pid=supervisor.child.pid, reason="job_id=$job_id")
        println(socket, "OK|STARTED|" * job_id)
        close(socket)
        handle.job_task = let accepted_reservation = reservation
            @async execute_listener_job!(handle, job, accepted_reservation)
        end
        reservation = nothing  # Execution task now owns this reservation.
    catch error
        if reservation !== nothing
            runtime_finish_job!(runtime, reservation.listener_id, reservation.server_id, reservation.job_id)
        end
        executor_audit(supervisor, "connection_error", runtime_snapshot(runtime); reason=sprint(showerror, error))
    end
    return nothing
end

function execute_listener_job!(handle::ListenerHandle, job, reservation)
    supervisor = handle.supervisor
    runtime = supervisor.runtime
    child = supervisor.child
    job_id = reservation.job_id
    started_at = Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS.sss")
    exec_status = "ERROR"
    callback_ok = false
    error_message = ""
    try
        child === nothing && throw(EOFError())
        request = ExecutorMessage("EXECUTE", reservation.listener_id, reservation.server_id, job_id,
            vcat([job.file_name, job.module_name, job.function_name], job.args))
        result = executor_exchange(child, request, "RESULT")
        if result.data[1] == "OK"
            exec_status = "OK"
            callback_ok = send_result(job, job_id, true; result=result.data[2])
        else
            error_message = result.data[2] * "|" * result.data[3]
            callback_ok = send_result(job, job_id, false; errType=result.data[2], errMsg=result.data[3])
        end
    catch error
        runtime_mark_unavailable!(runtime, reservation.listener_id, reservation.server_id)
        error_message = "EXECUTOR_UNAVAILABLE|" * sprint(showerror, error)
        callback_ok = send_result(job, job_id, false; errType="EXECUTOR_UNAVAILABLE",
            errMsg="Executor result unavailable; task side effects may have occurred: " * sprint(showerror, error))
    finally
        try
            send_done_notification(job, job_id, string(handle.bind_ip), handle.port;
                status=exec_status, started_at,
                finished_at=Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS.sss"),
                callback_ok, error_message)
        finally
            runtime_finish_job!(runtime, reservation.listener_id, reservation.server_id, job_id)
            executor_audit(supervisor, "job_finished", reservation;
                pid=child === nothing ? 0 : child.pid, reason="job_id=$job_id status=$exec_status callback_ok=$callback_ok")
        end
    end
    return nothing
end

function stop_listener!(handle::ListenerHandle)
    runtime_request_stop!(handle.supervisor.runtime)
    close(handle.socket)
    handle.accept_task === nothing || wait(handle.accept_task)
    # Close only request sockets; accepted jobs are owned by job_task.
    pending = collect(handle.connections)
    for (socket, _) in pending
        close(socket)
    end
    for (_, task) in pending
        wait(task)
    end
    handle.startup_task === nothing || wait(handle.startup_task)
    handle.job_task === nothing || wait(handle.job_task)
    return stop_executor!(handle.supervisor)
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
function has_conductor_metadata(job::SyncopadeJob)::Bool
    return !isempty(job.task_id) &&
        !isempty(job.conductor_ip_addr) &&
        job.conductor_port > 0
end

function build_result_payload(
    job::SyncopadeJob,
    jobId::String,
    ok::Bool;
    result::String="",
    errType::String="",
    errMsg::String=""
)::String
    isempty(jobId) && throw(ArgumentError("jobId must not be empty"))
    fields = has_conductor_metadata(job) ?
        String["TASK_RESULT", job.task_id, jobId] :
        String["RESULT", jobId]
    if ok
        push!(fields, "OK")
        push!(fields, result)
    else
        isempty(errType) && throw(ArgumentError("errType must not be empty"))
        push!(fields, "ERROR")
        push!(fields, errType)
        push!(fields, errMsg)
    end
    return build_payload(fields)
end

function send_result(job::SyncopadeJob, jobId::String, ok::Bool; result::String="", errType::String="", errMsg::String="")::Bool
    payload = build_result_payload(
        job,
        jobId,
        ok;
        result=result,
        errType=errType,
        errMsg=errMsg
    )
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

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
