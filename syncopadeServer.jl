using Sockets
using UUIDs

const server_state = Ref(:idle)  # :idle or :busy


# 以下関数群 ############################################################

# NOTE: getipaddr() は IPv4/IPv6 オブジェクトを返すため、string() に変換してから split する
# syncopade_serverのラッパー関数
# 引数がないバージョン．指定しないとIPアドレスの最下位の数字＋8000がポートになる
function syncopade_server()
    ip_parts = split(string(getipaddr()), '.')
    last_octet = parse(Int, ip_parts[end])
    port = last_octet + 8000

    println("Starting syncopade server on port ", port, " ... ")
    println("server IP address: ", string(getipaddr()))
    syncopade_server(port)
end


# syncopadeクライアントからのデータを受信する
# メッセージのフォーマットは
# clientIP|clientPort|file:module:func|arg1|arg2|...|CHECKSUM
# CHECKSUMはpayload（最後の|より前の全て）に対するXORチェックサム（16進）
# 即時応答は OK|STARTED|jobId でソケットはすぐ閉じる
# 計算終了後，computeサーバーはclientIP:clientPortに接続し，
# RESULT|jobId|OK|<string(result)>|CHECKSUM
# またはエラー時は
# RESULT|jobId|ERROR|<errorType>|<errorMessage>|CHECKSUM
# を送信する
function syncopade_server(port::Int)
    # Explicitly bind to detected local IP address to allow LAN access (not just localhost)
    bind_ip = getipaddr()
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
                        try
                            result = call_func(job.file_name, job.module_name, job.function_name, job.args)
                            send_result(job, jobId, true; result=string(result))
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
                            send_result(job, jobId, false; errType=errType, errMsg=errMsg)
                        finally
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

    args = length(parts) > 3 ? parts[4:end] : String[]

    return SyncopadeJob(client_ip_addr, client_port, file_name, module_name, function_name, args)
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
function send_result(job::SyncopadeJob, jobId::String, ok::Bool; result::String="", errType::String="", errMsg::String="")
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
    catch e
        println("Failed to send callback to $(job.client_ip_addr):$(job.client_port): ", e)
    end
end

# リモートから指定されたプログラムファイルを開いて関数を実行する
# args はすべて String として渡される
# 型変換は呼び出される関数側で行う
# 呼び出しの戻り値はそのまま返される．Stringを返すこと
function call_func(file_name::String, module_name::String, func_name::String, args::Vector{String}=String[])
    include(file_name * ".jl")

    mod = Base.invokelatest(getfield, Main, Symbol(module_name))
    f   = Base.invokelatest(getfield, mod,  Symbol(func_name))

    return Base.invokelatest(f, args...) 
end
