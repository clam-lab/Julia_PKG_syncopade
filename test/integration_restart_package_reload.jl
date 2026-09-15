using Test
include(joinpath(@__DIR__, "listener_test_support.jl"))
include(joinpath(@__DIR__, "..", "src", "Syncopade.jl"))

function package_restart_case(mode)
    mktempdir() do assets
        fixtures = joinpath(@__DIR__, "fixtures", "package_reload")
        first, second = joinpath(assets, "first"), joinpath(assets, "second")
        cp(joinpath(fixtures, "v1"), first)
        cp(joinpath(fixtures, "v2"), second)
        for root in (first, second)
            cp(joinpath(fixtures, "deployment_task.jl"), joinpath(root, "task.jl"))
        end
        with_test_listener() do handle, dir, audit
            callback = listen(ip"127.0.0.1", 0)
            before = Syncopade.query_server_runtime("127.0.0.1"; server_port=handle.port)
            socket, port = handle.socket, handle.port
            function execute(source, module_name)
                response = listener_request(handle, listener_task_payload(callback, "run"; fixture=source, module_name))
                @test startswith(response, "OK|STARTED|")
                result = receive_listener_callback(callback)
                @test result[1:3] == ["RESULT", split(response, '|')[3], "OK"]
                wait_listener_state(handle, :idle)
                return join(result[4:end], '|')
            end
            try
                standalone = joinpath(dir, "standalone.jl")
                cp(joinpath(fixtures, "task_v1.jl"), standalone)
                @test execute(standalone, "StandaloneTask") == "V1"
                cp(joinpath(fixtures, "task_v2.jl"), standalone; force=true)
                @test listener_request(handle, "CACHE_CLEAR") == "CACHE|CLEARED|1"
                @test execute(standalone, "StandaloneTask") == "V2"
                @test handle.supervisor.child.pid == before.server_pid
                @test listener_request(handle, "CACHE_CLEAR") == "CACHE|CLEARED|1"
                source = joinpath(first, "task.jl")
                old_path = joinpath(first, "ReloadProbe", "src", "ReloadProbe.jl")
                v1 = split(execute(source, "PackageTask"), '|')
                @test v1 == ["V1", string(before.server_pid), old_path]
                if mode == "overwrite"
                    cp(joinpath(second, "ReloadProbe", "src", "ReloadProbe.jl"), old_path; force=true)
                    new_path = old_path
                    clear_count = 1
                else
                    @test mode == "switch"
                    source = joinpath(second, "task.jl")
                    new_path = joinpath(second, "ReloadProbe", "src", "ReloadProbe.jl")
                    clear_count = 2
                end
                @test split(execute(source, "PackageTask"), '|') == v1
                @test listener_request(handle, "CACHE_CLEAR") == "CACHE|CLEARED|$clear_count"
                @test split(execute(source, "PackageTask"), '|') == v1
                still_old = Syncopade.query_server_runtime("127.0.0.1"; server_port=handle.port)
                @test still_old.server_id == before.server_id
                result = Syncopade.restart_server_executor("127.0.0.1"; server_port=handle.port,
                    expected_listener_id=before.listener_id, expected_server_id=before.server_id)
                @test result.status == :success
                after = result.runtime
                @test after.listener_id == before.listener_id
                @test after.listener_pid == before.listener_pid
                @test after.server_id != before.server_id
                @test after.server_pid != before.server_pid
                @test after.ready
                @test handle.socket === socket
                @test handle.port == port
                @test split(execute(source, "PackageTask"), '|') == ["V2", string(after.server_pid), new_path]
                @test split(execute(source, "PackageTask"), '|') == ["V2", string(after.server_pid), new_path]
                @test handle.supervisor.child.pid == after.server_pid
                @test !any(id -> id.name == "ReloadProbe", keys(Base.loaded_modules))
                println("PUBLIC_PACKAGE_RELOAD mode=$mode compiled=$(Base.JLOptions().use_compiled_modules) listener=$(after.listener_id) parent_pid=$(getpid()) old_server=$(before.server_id) old_pid=$(before.server_pid) new_server=$(after.server_id) new_pid=$(after.server_pid) old_path=$old_path new_path=$new_path")
            finally
                close(callback)
            end
        end
    end
end

if isempty(ARGS)
    @testset "Public package restart isolated cases" begin
        for compiled in ("yes", "no"), mode in ("overwrite", "switch")
            command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) --threads=4 --compiled-modules=$compiled $(@__FILE__) $mode`
            process = run(ignorestatus(command))
            @test process.exitcode == 0
        end
    end
else
    @testset "Public package restart $(ARGS[1])" begin
        package_restart_case(ARGS[1])
    end
end
