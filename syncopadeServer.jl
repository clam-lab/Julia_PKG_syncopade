using Sockets

# syncopadeクライアントからのデータを受信する
# メッセージのフォーマットは FILENAME_MODULENAME_FUNCNAME_ARGS|CHECKSUM
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
                result = call_func(fileName, moduleName, funcName, args)

                # 結果をクライアントに返す
                println(sock, result)

                # ソケットを閉じる
                close(sock)
            end
        end
    end    
end

# 受け取ったメッセージの生データをもらって，チェックサムを切り離してチェック
# うまくいったらtrue + 残りのメッセージを返して，失敗したらfalseを返す
function checksum(msg::String)
    parts = split(chomp(msg), '|')
    if length(parts) != 2
        return false, ""
    end

    data = parts[1]

    # チェックサムは16進数表記前提（例: "8f" や "0A"）
    recv_checksum = try
        parse(UInt8, parts[2], base=16)
    catch
        return false, ""
    end

    calc_checksum = geneXORchecksum(data)

    if recv_checksum == calc_checksum
        return true, data
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

function convMSG2ARGS(msg::String)
    parts = split(chomp(msg), '_')
    return parts[1], parts[2], parts[3], parts[4:end]
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
