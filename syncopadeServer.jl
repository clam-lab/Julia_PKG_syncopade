using Sockets

# syncopadeクライアントからのデータを受信する
# メッセージのフォーマットは FILENAME_MODULENAME_FUNCNAME_ARGS|CHECKSUM
function server(port::Int)
    server = listen(port)  # 指定されたポート番号で待つ

    @async begin
        while true
            sock = accept(server)
            @async begin
                row_msg = readline(sock)
                ok, msg = checksum(row_msg)
                if !ok
                    println("Checksum error!")
                    close(sock)
                    continue
                end

                fileName, moduleName, funcName, args = convMSG2ARGS(msg)

                write(sock, "hello from Julia\n")
                close(sock)
            end
        end
    end    
end

# 受け取ったメッセージの生データをもらって，チェックサムを切り離してチェック
# うまくいったらtrue + 残りのメッセージを返して，失敗したらfalseを返す
function checksum(msg:String)
    parts = split(chomp(msg), '|')
    if length(parts) != 2
        return false, ""
    end

    data = parts[1]
    recv_checksum = parse(UInt8, parts[2])

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

function convMSG2ARGS(msg::String)
    parts = split(chomp(msg), '_')
    return parts[1], parts[2], parts[3], parts[4:end]
end



function call_func(file_name::String, module_name::String, func_name::String)
    include(file_name * ".jl")

    mod = getfield(Main, Symbol(module_name))
    f = getfield(mod, Symbol(func_name))

    return f()
end

call_func("testScript", "testScript4syncopade", "test_syncopade")