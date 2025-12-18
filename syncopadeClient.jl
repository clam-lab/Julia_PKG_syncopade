using Sockets

# syncopade_serverに接続するためのクライアントの構造体
struct SyncopadeClient
    sever_ip_addr::String
    server_port::Int
    self_ip_addr::String
    self_port::Int
    file_name::String
    module_name::String
    function_name::String
    args::Vector{String}
end

# syncopade_serverに接続するためのクライアントのコード
function syncopade_calc_request(pList::SyncopadeClient)
    sock = connect(pList.server_ip_addr, pList.server_port)

    # メッセージの作成
    # フォーマットは fileName|moduleName|funcName|arg1|arg2|...|CHECKSUM
    msg = join([pList.file_name, pList.module_name, pList.function_name, join(pList.args, "|")], "|")
    msg_with_checksum = add_checksum(msg)   
    println(sock, msg_with_checksum)

    println(readline(sock))
    close(sock)
end



# チェックサムを計算する関数
function geneXORchecksum(s::String)
    c = UInt8(0)
    for b in codeunits(s)
        c ⊻= b
    end
    return c
end