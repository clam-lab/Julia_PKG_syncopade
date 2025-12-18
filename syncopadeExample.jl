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

# ２．ソケットを使うので Sockets を使う
using Sockets

# ３．syncopadeClient.jl を読み込む
include("syncopadeClient.jl")

# ４．サーバの状態を問い合わせる
status = query_server_status("192.168.2.99", 8099)
println("server status = ", status)

# ５．サーバがアイドル状態でなければ終了
if status != "STATUS|idle"
    println("server is busy now. aborting request.")
    return
end

## ここまでは準備コード．以下でクライアントを作成してジョブを送信する．

# ６．結果受信サーバを起動　ポート番号は任意　クライアントと被らなければ良い
syncopade_result_server_once(9001, result_handler)

# 7. クライアントの設定を作る
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

# 8. ジョブを送信
jobId = syncopade_calc_request(client)
println("submitted jobId = ", jobId)

