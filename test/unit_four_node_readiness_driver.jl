using Test
using Sockets
using UUIDs
include("integration_four_node_readiness.jl")
const R = FourNodeReadiness

"""Local protocol peer only. No Syncopade executor, shared write, or LAN access."""
function with_peer(f; mode=:direct, behavior=:ok)
    listener = listen(ip"127.0.0.1", 0)
    port = Int(getsockname(listener)[2])
    sockets = TCPSocket[]
    handlers = Task[]
    submissions = Ref(0)
    received = Vector{Vector{SubString{String}}}()
    errors = Any[]
    listener_id, server_id, changed_id = string.((uuid4(), uuid4(), uuid4()))
    job_id, task_id = "readiness-job", "readiness-task"

    loop = @async while isopen(listener)
        sock = try
            accept(listener)
        catch
            break
        end
        push!(sockets, sock)
        handler = @async try
            payload = R.checked_payload(readline(sock))
            fields = split(payload, '|')
            if payload == "RUNTIME"
                identity = behavior == :identity_changed && submissions[] > 0 ? changed_id : server_id
                runtime = R.ServerRuntimeInfo(listener_id, identity, :idle, 100, 101, "test", "0.1.5", true)
                println(sock, R.management_response(vcat(["RUNTIME", "1"], R.management_runtime_fields(runtime))))
            elseif payload == "LIST"
                node_ip = behavior == :wrong_lan ? "192.168.100.104" : "127.0.0.1"
                println(sock, R.add_checksum("NODES|$node_ip:$port"))
            elseif startswith(payload, "TASK_STATUS|")
                terminal_job = behavior == :wrong_terminal_job ? "another-job" : job_id
                kind = behavior == :terminal_error ? "WORKER_DONE_ERROR" : "WORKER_DONE_OK"
                println(sock, R.add_checksum("TASK_STATUS|KNOWN|$task_id|terminal|$terminal_job|$kind|"))
            else
                submissions[] += 1
                push!(received, fields)
                callback_fields = mode == :conductor ? fields[2:end] : fields
                callback_ip, callback_port = callback_fields[1:2]
                @assert callback_fields[3] == "$(abspath(R.FIXTURE)):syncopadeBasicTestScript:test"
                @assert callback_fields[4:end] == ["[2,3,5]", "[7,11,13]"]
                @assert mode != :conductor || fields[1] == "SUBMIT"
                ack = mode == :conductor ? R.add_checksum("OK|QUEUED|$task_id") : "OK|STARTED|$job_id"
                if behavior == :busy
                    println(sock, "ERROR|BUSY")
                    return nothing
                elseif behavior == :ack_timeout
                    sleep(0.6)
                    return nothing
                end
                behavior == :early_callback || println(sock, ack)
                if behavior != :no_callback
                    callback = connect(parse(IPv4, callback_ip), parse(Int, callback_port))
                    push!(sockets, callback)
                    if behavior != :silent_callback
                        callback_job = behavior == :wrong_job ? "another-job" : job_id
                        callback_task = behavior == :wrong_task ? "another-task" : task_id
                        prefix = mode == :conductor ? "TASK_RESULT|$callback_task|$callback_job" : "RESULT|$callback_job"
                        outcome = behavior == :error ? "ERROR|FixtureError|deliberate" :
                            behavior == :wrong_value ? "OK|30031.0" : "OK|30030.0"
                        row = R.add_checksum("$prefix|$outcome")
                        println(callback, behavior == :bad_checksum ? row * "invalid" : row)
                        close(callback)
                    end
                end
                behavior == :early_callback && println(sock, ack)
            end
        catch exception
            push!(errors, exception)
        finally
            close(sock)
        end
        push!(handlers, handler)
    end
    try
        f((; port, submissions, received, errors))
    finally
        close(listener)
        foreach(close, sockets)
        wait(loop)
        foreach(wait, handlers)
        @test isempty(errors)
        @test all(istaskdone, handlers)
        @test all(socket -> !isopen(socket), sockets)
        replacement = listen(ip"127.0.0.1", port)
        close(replacement)
        @test !isopen(replacement)
    end
end

function probe(peer, mode, io; timeout=5.0)
    return R.run_probe(mode, "127.0.0.1", peer.port, "127.0.0.1", 0,
        abspath(R.FIXTURE), timeout; io)
end

@testset "four-node readiness driver: local only" begin
    @testset "input guards without connection" begin
        source = abspath(R.FIXTURE)
        @test length(R.validate_inputs(:direct, "127.0.0.1", 1, "127.0.0.1", 0, source, 1.0)) == 64
        @test_throws ErrorException R.validate_inputs(:invalid, "127.0.0.1", 1, "127.0.0.1", 0, source, 1.0)
        @test_throws ErrorException R.validate_inputs(:direct, "127.0.0.1", 0, "127.0.0.1", 0, source, 1.0)
        @test_throws ErrorException R.validate_inputs(:direct, "127.0.0.1", 1, "127.0.0.1", -1, source, 1.0)
        @test_throws ErrorException R.validate_inputs(:direct, "127.0.0.1", 1, "127.0.0.1", 0, "relative.jl", 1.0)
        @test_throws ErrorException R.validate_inputs(:direct, "127.0.0.1", 1, "127.0.0.1", 0, source, Inf)
        @test_throws ErrorException R.validate_inputs(:direct, "127.0.0.1", 1, "192.168.100.2", 0, source, 1.0)
        @test_throws ErrorException R.validate_inputs(:direct, "127.0.0.1", 1, "127.0.0.1", 0, abspath(@__FILE__), 1.0)
        @test_throws ErrorException R.main(String[])
    end

    @testset "other LAN rejected before runtime or submission" begin
        with_peer(; mode=:conductor, behavior=:wrong_lan) do peer
            @test_throws "LIST contains another LAN" probe(peer, :conductor, IOBuffer())
            @test peer.submissions[] == 0
        end
    end

    for mode in (:direct, :conductor), behavior in (:ok, :early_callback)
        @testset "$mode / $behavior" begin
            with_peer(; mode, behavior) do peer
                io = IOBuffer()
                result = probe(peer, mode, io)
                audit = String(take!(io))
                @test result.result == "30030.0"
                @test result.job_id == "readiness-job"
                @test result.task_id == (mode == :conductor ? "readiness-task" : "")
                @test result.worker_ip == "127.0.0.1"
                @test result.worker_port == peer.port
                @test peer.submissions[] == 1
                @test length(peer.received) == 1
                @test occursin("event=idle_restored", audit)
                @test occursin("event=callback_closed_and_rebind_verified", audit)
                @test mode != :conductor || occursin("WORKER_DONE_OK", audit)
                listener = listen(ip"127.0.0.1", result.callback_port)
                close(listener)
                @test !isopen(listener)
            end
        end
    end

    @testset "explicit CLI log and no overwrite" begin
        with_peer() do peer
            mktempdir() do directory
                log_path = joinpath(directory, "probe.log")
                args = ["direct", "127.0.0.1", string(peer.port), "127.0.0.1", "0",
                    abspath(R.FIXTURE), "5.0", log_path]
                R.main(args)
                original = read(log_path, String)
                @test occursin("event=PASS", original)
                @test_throws ErrorException R.main(args)
                @test read(log_path, String) == original
                @test peer.submissions[] == 1
            end
        end
    end

    cases = [(:direct, :error, "worker returned ERROR"),
        (:direct, :wrong_job, "job ID mismatch"),
        (:direct, :wrong_value, "wrong result"),
        (:direct, :bad_checksum, "checksum mismatch"),
        (:direct, :identity_changed, "executor identity changed"),
        (:direct, :busy, "rejected task as busy"),
        (:direct, :no_callback, "callback timed out"),
        (:direct, :silent_callback, "callback timed out"),
        (:direct, :ack_timeout, "management request timed out"),
        (:conductor, :error, "worker returned ERROR"),
        (:conductor, :wrong_task, "task ID mismatch"),
        (:conductor, :wrong_terminal_job, "terminal job ID mismatch"),
        (:conductor, :terminal_error, "abnormal terminal kind"),
        (:conductor, :no_callback, "callback timed out")]
    for (mode, behavior, expected_error) in cases
        @testset "$mode / $behavior" begin
            with_peer(; mode, behavior) do peer
                io = IOBuffer()
                exception = try
                    probe(peer, mode, io; timeout=0.2)
                    nothing
                catch caught
                    caught
                end
                audit = String(take!(io))
                @test exception !== nothing
                @test occursin(expected_error, sprint(showerror, exception))
                @test peer.submissions[] == 1
                @test occursin("event=failure", audit)
                @test occursin("event=reconcile_runtime", audit)
                @test occursin("event=callback_closed_and_rebind_verified", audit)
                @test !occursin("event=result_verified", audit)
                @test mode != :conductor || occursin("event=reconcile_task", audit)
            end
        end
    end
end
