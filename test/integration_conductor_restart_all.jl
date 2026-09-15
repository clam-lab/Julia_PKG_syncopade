include(joinpath(@__DIR__, "conductor_listener_test_support.jl"))
include(joinpath(@__DIR__, "listener_process_test_support.jl"))

@testset "Two listener processes replace executors through conductor" begin
    mktempdir() do dir
        packages = joinpath(dir, "deployment")
        fixtures = joinpath(@__DIR__, "fixtures", "package_reload")
        cp(joinpath(fixtures, "v1"), packages)
        source = joinpath(packages, "task.jl")
        cp(joinpath(fixtures, "deployment_task.jl"), source)
        entered, release = joinpath(dir, "stop-entered"), joinpath(dir, "stop-release")
        nodes = Any[]
        conductor = nothing
        callback = listen(ip"127.0.0.1", 0)
        try
            push!(nodes, start_listener_process(mkdir(joinpath(dir, "node1")); extra_env=Dict(
                "SYNCOPADE_TEST_EXECUTOR_SCRIPT" => joinpath(@__DIR__, "fixtures", "gated_executor.jl"),
                "SYNCOPADE_STOP_ENTERED" => entered, "SYNCOPADE_STOP_RELEASE" => release,
                "SYNCOPADE_EXECUTOR_SHUTDOWN_TIMEOUT" => "20")))
            push!(nodes, start_listener_process(mkdir(joinpath(dir, "node2"))))
            endpoints = [(ip="127.0.0.1", port=node.port, name="node$index") for (index, node) in enumerate(nodes)]
            conductor = start_local_conductor(endpoints, mkdir(joinpath(dir, "conductor")); monitor=true)
            before = [Syncopade.query_server_runtime("127.0.0.1"; server_port=node.port) for node in nodes]
            @test length(unique(vcat([info.listener_pid for info in before], [info.server_pid for info in before], [getpid(conductor.process)]))) == 5
            function marker(node)
                response = listener_request(node, listener_task_payload(callback, "run"; fixture=source, module_name="PackageTask"))
                @test startswith(response, "OK|STARTED|")
                result = receive_listener_callback(callback)
                @test result[3] == "OK"
                @test timedwait(() -> Syncopade.query_server_runtime("127.0.0.1"; server_port=node.port).state == :idle, 10; pollint=0.01) == :ok
                return result[4:6]
            end
            for (node, info) in zip(nodes, before)
                @test marker(node)[1:2] == ["V1", string(info.server_pid)]
            end
            cp(joinpath(fixtures, "v2", "ReloadProbe", "src", "ReloadProbe.jl"), joinpath(packages, "ReloadProbe", "src", "ReloadProbe.jl"); force=true)
            id = string(uuid4())
            started = Syncopade.start_conductor_executor_restart("127.0.0.1"; conductor_port=conductor.port, operation_id=id)
            @test started.state == :running
            @test timedwait(() -> isfile(entered), 10; pollint=0.01) == :ok
            @test timedwait(10; pollint=0.02) do
                info = Syncopade.query_server_runtime("127.0.0.1"; server_port=nodes[2].port)
                info.server_id != before[2].server_id && info.ready
            end == :ok
            @test Syncopade.query_server_runtime("127.0.0.1"; server_port=nodes[1].port).state == :restarting
            rejected = local_conductor_request(conductor, "SUBMIT|127.0.0.1|$(getsockname(callback)[2])|source:Module:run")
            @test checksum(rejected)[2] == "ERROR|BUSY|MAINTENANCE"
            write(release, "release")
            complete = Syncopade.wait_conductor_executor_restart("127.0.0.1"; conductor_port=conductor.port, operation_id=id, timeout=15)
            @test complete.summary == (total_nodes=2, success_nodes=2, failed_nodes=0, overall_success=true)
            after = [Syncopade.query_server_runtime("127.0.0.1"; server_port=node.port) for node in nodes]
            for (index, node) in enumerate(nodes)
                @test after[index].listener_id == before[index].listener_id
                @test after[index].listener_pid == before[index].listener_pid
                @test after[index].server_id != before[index].server_id
                @test after[index].server_pid != before[index].server_pid
                @test marker(node) == ["V2", string(after[index].server_pid), joinpath(packages, "ReloadProbe", "src", "ReloadProbe.jl")]
            end
            tasks = Dict{String,String}()
            traces = String[]
            for label in ("1", "2", "3", "4")
                trace = joinpath(dir, "trace-$label.csv")
                push!(traces, trace)
                tasks[submit_local_probe(conductor, callback, "counted", [trace, label])] = label
            end
            verify_probe_batch(conductor, callback, tasks, [info.server_pid for info in after], traces)
            for node in nodes
                @test timedwait(() -> Syncopade.query_server_runtime("127.0.0.1"; server_port=node.port).state == :idle, 10; pollint=0.01) == :ok
            end
            stop_local_conductor(conductor)
            conductor = nothing
            unused = listen(ip"127.0.0.1", 0)
            down_port = Int(getsockname(unused)[2])
            close(unused)
            conductor = start_local_conductor(vcat(endpoints, [(ip="127.0.0.1", port=down_port, name="offline")]), mkdir(joinpath(dir, "partial")))
            # An old operation ID is unknown to a new conductor; querying must not restart anything.
            @test Syncopade.query_conductor_executor_restart("127.0.0.1"; conductor_port=conductor.port, operation_id=id).state == :unknown
            @test [Syncopade.query_server_runtime("127.0.0.1"; server_port=node.port).server_id for node in nodes] == [info.server_id for info in after]
            partial = Syncopade.start_conductor_executor_restart("127.0.0.1"; conductor_port=conductor.port)
            partial = Syncopade.wait_conductor_executor_restart("127.0.0.1"; conductor_port=conductor.port, operation_id=partial.operation_id, timeout=15)
            @test partial.summary == (total_nodes=3, success_nodes=2, failed_nodes=1, overall_success=false)
            @test length(partial.nodes) == 3
            @test only(node for node in partial.nodes if node.name == "offline").result.status == :transport_error
            println("CONDUCTOR_REAL_BULK listeners=$([info.listener_id for info in before]) listener_pids=$([info.listener_pid for info in before]) old_executor_pids=$([info.server_pid for info in before]) new_executor_pids=$([info.server_pid for info in after]) tasks=4 partial=2/3")
        finally
            write(release, "release")
            conductor === nothing || stop_local_conductor(conductor)
            for node in nodes
                stop_listener_process(node)
            end
            close(callback)
        end
    end
end
