using Sockets

# メインのサーバー起動関数
syncopade_server()



# 以下関数群 ############################################################

# syncopade_serverのラッパー関数
# 引数がないバージョン．指定しないとIPアドレスの最下位の数字＋8000がポートになる
function syncopade_server()
    ip_parts = split(getipaddr(), '.')
    last_octet = parse(Int, ip_parts[end])
    port = last_octet + 8000
    syncopade_server(port)
end


# syncopadeクライアントからのデータを受信する
# メッセージのフォーマットは file:module:func|arg1|arg2|...|CHECKSUM
function syncopade_server(port::Int)
    server = listen(port)  # 指定されたポート番号で待つ

    @async begin
        while true
            # クライアントからの接続を待つ
            sock = accept(server)
            @async begin
                # クライアントからのメッセージを受信
                row_msg = readline(sock)
                # チェックサムを検証
                ok, msg = checksum(row_msg)
                # チェックサムエラーならばソケットを閉じて次へ
                if !ok
                    println("Checksum error!")
                    close(sock)
                    continue
                end

                # メッセージを解析して関数呼び出し
                fileName, moduleName, funcName, args = convMSG2ARGS(msg)

                # 関数を呼び出して結果を得る
                # エラーハンドリング付き
                try
                    result = call_func(fileName, moduleName, funcName, args)
                      # 結果をクライアントに返す
                    println(sock, "OK|" * string(result))
                catch e
                    msg = if e isa LoadError
                        "LOAD_ERROR|" * sprint(showerror, e)
                    elseif e isa UndefVarError
                        "NAME_ERROR|" * sprint(showerror, e)
                    elseif e isa MethodError
                        "METHOD_ERROR|" * sprint(showerror, e)
                    elseif e isa ArgumentError
                        "ARG_ERROR|" * sprint(showerror, e)
                    else
                        "RUNTIME_ERROR|" * sprint(showerror, e)
                    end
                    println(sock, msg)
                end
                close(sock)

                # ソケットを閉じる
                close(sock)
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

# geneXORchecksum は UInt8 を返す。
# 送信側では hex string（例: lowercase(hex(checksum))）にして送る前提。

# payload のフォーマット:
# file:module:func|arg1|arg2|...
function convMSG2ARGS(msg::String)
    parts = split(chomp(msg), '|')
    if length(parts) < 1
        error("Invalid message format: $msg")
    end

    head = parts[1]
    head_parts = split(head, ':')

    if length(head_parts) != 3
        error("Invalid command header: $head")
    end

    fileName   = head_parts[1]
    moduleName = head_parts[2]
    funcName   = head_parts[3]

    args = length(parts) >= 2 ? parts[2:end] : String[]

    return fileName, moduleName, funcName, args
end

# リモートから指定されたプログラムファイルを開いて関数を実行する
# args はすべて String として渡される
# 型変換は呼び出される関数側で行う
# 呼び出しの戻り値はそのまま返される．Stringを返すこと
function call_func(file_name::String, module_name::String, func_name::String, args::Vector{String}=String[])
    include(file_name * ".jl")

    mod = getfield(Main, Symbol(module_name))
    f = getfield(mod, Symbol(func_name))

    return f(args...)
end
