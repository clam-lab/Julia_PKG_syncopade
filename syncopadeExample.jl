# １．サーバが実行完了時に返事が届いた時に呼び出される関数
# jobId: ジョブID
# ok: trueなら成功 falseなら失敗
# value: okがtrueなら結果値、falseならエラー情報
# 何か実行したいならここを書き換える
function result_handler(jobId, ok, value)
    println("RESULT:")
    println(" jobId = ", jobId)
    println(" ok    = ", ok)
    println(" value = ", value)
end

using Sockets

include("syncopadeClient.jl")

status = query_server_status("192.168.2.99", 8099)
println("server status = ", status)

if status != "STATUS|idle"
    println("server is busy now. aborting request.")
    return
end

syncopade_result_server_once(9001, result_handler)

client = SyncopadeClient(
    "192.168.2.99",  # server ip
    8099,         # server port（環境に合わせて）
    "192.168.2.99",  # self ip 自分のIPアドレス
    9001,         # self port　なんでもいい 数字を変えればパラレルで複数作れる
    "testScript", # .jl file name（拡張子なし）
    "testScript4syncopade", # module name
    "test_syncopade", # function name
    ["hogehoge"] # args
)

jobId = syncopade_calc_request(client)
println("submitted jobId = ", jobId)