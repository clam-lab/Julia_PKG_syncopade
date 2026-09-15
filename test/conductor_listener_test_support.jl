include(joinpath(@__DIR__, "listener_test_support.jl"))
include(joinpath(@__DIR__, "..", "src", "Syncopade.jl"))
include(joinpath(@__DIR__, "conductor_process_test_support.jl"))
using .LocalConductorTestSupport

function submit_local_probe(conductor, callback, function_name, args=String[])
    return String(Syncopade.submit_conductor_task("127.0.0.1"; conductor_port=conductor.port,
        coordinator_ip="127.0.0.1", coordinator_port=Int(getsockname(callback)[2]),
        source=joinpath(@__DIR__, "fixtures", "listener_probe.jl"), module_name="ListenerProbe", function_name, args))
end

function terminal_status(conductor, task_id)
    last = Ref{Any}(nothing)
    @test timedwait(10; pollint=0.02) do
        last[] = Syncopade.query_conductor_task_status("127.0.0.1", task_id; conductor_port=conductor.port)
        last[] isa Syncopade.KnownConductorTaskStatus && last[].state == :terminal
    end == :ok
    return last[]
end

function verify_probe_batch(conductor, callback, tasks, allowed_pids, trace)
    results = [receive_listener_callback(callback) for _ in 1:length(tasks)]
    @test all(result -> result[1] == "TASK_RESULT" && result[4] == "OK", results)
    @test Set(result[2] for result in results) == Set(keys(tasks))
    @test length(unique(result[3] for result in results)) == length(tasks)
    for result in results
        fields = split(result[5], ',')
        @test fields[1] == tasks[result[2]]
        @test parse(Int, fields[2]) in allowed_pids
        @test fields[3] == "1"
        status = terminal_status(conductor, result[2])
        @test status.job_id == result[3]
        @test status.terminal_kind == "WORKER_DONE_OK"
    end
    lines = trace isa AbstractVector ? reduce(vcat, readlines.(trace); init=String[]) : readlines(trace)
    @test length(lines) == 2length(tasks)
    @test sort([split(line, ',')[2] for line in lines if startswith(line, "START,")]) == sort(collect(values(tasks)))
    @test all(line -> split(line, ',')[4] == (startswith(line, "START,") ? "1" : "0"), lines)
    return results
end
