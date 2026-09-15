include(joinpath(@__DIR__, "..", "..", "syncopadeServer.jl"))
script = get(ENV, "SYNCOPADE_TEST_EXECUTOR_SCRIPT", joinpath(@__DIR__, "..", "..", "scripts", "run_executor.jl"))
handle = syncopade_server(ip"127.0.0.1", 0; config=ExecutorLaunchConfig(; script))
println("LOCAL_LISTENER_PORT=$(handle.port)")
flush(stdout)
try
    while !eof(stdin)
        strip(readline(stdin)) == "q" && break
    end
finally
    result = stop_listener!(handle)
    println("LOCAL_LISTENER_STOP ok=$(result.ok)")
    result.ok || error("test listener cleanup failed")
end
