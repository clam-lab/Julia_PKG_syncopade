include("syncopadeClient.jl")

# 2. クライアント側の結果受信用サーバ
syncopade_result_server(9001) do jobId, ok, value
    println("RESULT:")
    println(" jobId = ", jobId)
    println(" ok    = ", ok)
    println(" value = ", value)
end

client = SyncopadeClient(
    "192.168.2.99",  # server ip
    8099,         # server port（環境に合わせて）
    "127.0.0.1",  # self ip
    9001,         # self port
    "testScript", # .jl file name（拡張子なし）
    "testScript4syncopade", # module name
    "test_syncopade", # function name
    String[] #args
)

jobId = syncopade_calc_request(client)
println("submitted jobId = ", jobId)