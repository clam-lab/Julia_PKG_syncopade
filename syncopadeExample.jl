include("syncopadeClient.jl")

# 2. クライアント側の結果受信用サーバ
syncopade_result_server(9001) do jobId, ok, value
    println("RESULT:")
    println(" jobId = ", jobId)
    println(" ok    = ", ok)
    println(" value = ", value)
end

client = SyncopadeClient(
    "127.0.0.1",  # server ip
    8000,         # server port（環境に合わせて）
    "127.0.0.1",  # self ip
    9001,         # self port
    "testScript",
    "testScript4syncopade",
    "test_syncopade",
    String[]
)

jobId = syncopade_calc_request(client)
println("submitted jobId = ", jobId)