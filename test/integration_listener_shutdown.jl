include(joinpath(@__DIR__, "listener_test_support.jl"))
include(joinpath(@__DIR__, "..", "src", "Syncopade.jl"))

const SHUTDOWN_ROOT = dirname(@__DIR__)
const SHUTDOWN_ENTRYPOINTS = [joinpath(SHUTDOWN_ROOT, "syncopadeServer.jl"),
    joinpath(SHUTDOWN_ROOT, "scripts", "run_server.jl")]

function owned_pid_exists(pid)
    Sys.isunix() || return false
    return ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0
end

function start_entrypoint(entrypoint, dir, depot; threads=nothing)
    output = open(joinpath(dir, "stdout"), "w+")
    errors = open(joinpath(dir, "stderr"), "w+")
    separator = Sys.iswindows() ? ';' : ':'
    thread_args = threads === nothing ? String[] : ["--threads=$threads"]
    command = `$(Base.julia_cmd()) --startup-file=no --project=$SHUTDOWN_ROOT $thread_args $entrypoint --bind 127.0.0.1 --port 0`
    command = Cmd(command; detach=true) # Isolate group signals from the test runner.
    command = addenv(command, "JULIA_DEPOT_PATH" => depot,
        "JULIA_LOAD_PATH" => join([joinpath(@__DIR__, "fixtures", "package_reload", "v1"), "@", "@stdlib"], separator))
    process = open(pipeline(command; stderr=errors), "w", output)
    port = 0
    info = nothing
    try
        ready = timedwait(25; pollint=0.05) do
            process_exited(process) && return true
            matched = match(r"bind address: 127\.0\.0\.1:(\d+)\n", read(joinpath(dir, "stdout"), String))
            matched === nothing && return false
            port = parse(Int, matched[1])
            try
                info = Syncopade.query_server_runtime("127.0.0.1"; server_port=port, timeout=0.5)
                return info.ready
            catch
                return false
            end
        end
        ready == :ok && !process_exited(process) && info !== nothing && info.ready ||
            error("entrypoint not ready: $(read(joinpath(dir, "stderr"), String))")
        return (; process, port, bind_ip=ip"127.0.0.1", info, output, errors, dir)
    catch
        process_running(process) && kill(process, Base.SIGKILL)
        wait(process)
        close(output)
        close(errors)
        rethrow()
    end
end

function request_entrypoint_stop(child, mode)
    if mode == :q
        write(child.process, "q\n")
        flush(child.process)
    elseif mode == :eof
        close(child.process.in)
    elseif mode == :sigint
        kill(child.process, Base.SIGINT)
    elseif mode == :group_sigint
        pid = getpid(child.process)
        group = ccall(:getpgid, Cint, (Cint,), pid)
        group == pid && group != ccall(:getpgrp, Cint, ()) || error("test does not own the listener process group")
        ccall(:kill, Cint, (Cint, Cint), -group, Base.SIGINT) == 0 || error("group SIGINT failed")
    end
end

function require_shutdown_wait(predicate, seconds, label)
    timedwait(predicate, seconds; pollint=0.01) == :ok || error("timeout waiting for $label")
    return true
end

function listener_port_closed(child)
    socket = TCPSocket()
    try
        connect(socket, child.bind_ip, child.port)
        return false
    catch
        return true
    finally
        close(socket)
    end
end

function cleanup_entrypoint(child, release)
    write(release, "release")
    if process_running(child.process)
        try
            request_entrypoint_stop(child, :q)
        catch
        end
        timedwait(() -> process_exited(child.process), 15; pollint=0.02) == :ok ||
            kill(child.process, Base.SIGKILL)
    end
    wait(child.process)
    require_shutdown_wait(() -> !owned_pid_exists(child.info.server_pid), 10, "owned executor exit")
    close(child.output)
    close(child.errors)
    close(child.process.in)
end

@testset "Server entrypoint arguments and include-only" begin
    @test server_entrypoint_options(String[]) === nothing
    @test server_entrypoint_options(["--help"]) === :help
    @test server_entrypoint_options(["--bind", "127.0.0.1", "--port", "0"]) == (ip=ip"127.0.0.1", port=0)
    @test server_entrypoint_options(["--port", "8099", "--bind", "127.0.0.1"]).port == 8099
    for args in (["--port", "0"], ["--bind", "127.0.0.1", "--port", "-1"],
        ["--bind", "127.0.0.1", "--port", "65536"], ["--bind", "127.0.0.1", "--port", "NaN"],
        ["--bind", "not-an-address", "--port", "0"], ["--port", "0", "--port", "1"],
        ["--unknown", "a", "--port", "0"])
        @test_throws ArgumentError server_entrypoint_options(args)
    end
    for entrypoint in SHUTDOWN_ENTRYPOINTS
        code = "include($(repr(entrypoint))); println(\"INCLUDE_ONLY_OK\")"
        command = `$(Base.julia_cmd()) --startup-file=no --project=$SHUTDOWN_ROOT --threads=4 -e $code -- --bind 127.0.0.1 --port 0`
        output, errors = IOBuffer(), IOBuffer()
        process = run(pipeline(ignorestatus(command); stdin=devnull, stdout=output, stderr=errors))
        @test process.exitcode == 0
        @test String(take!(output)) == "INCLUDE_ONLY_OK\n"
        @test isempty(take!(errors))
    end
end

@testset "Signal event preserves independent work" begin
    if Sys.isunix()
        mktempdir() do dir
            output, errors = IOBuffer(), IOBuffer()
            command = `$(Base.julia_cmd()) --startup-file=no --threads=4 $(joinpath(@__DIR__, "fixtures", "shutdown_signal_probe.jl")) $dir`
            process = run(pipeline(command; stdout=output, stderr=errors); wait=false)
            try
                @test require_shutdown_wait(() -> isfile(joinpath(dir, "ready")), 10, "signal probe entry")
                kill(process, Base.SIGINT)
                @test require_shutdown_wait(() -> isfile(joinpath(dir, "hook_entered")), 5, "signal event")
                @test read(joinpath(dir, "hook_entered"), String) == "self_wait=false"
                @test process_running(process)
                write(joinpath(dir, "release"), "release")
                @test require_shutdown_wait(() -> process_exited(process), 5, "signal probe exit")
                @test isfile(joinpath(dir, "work_done"))
                @test isfile(joinpath(dir, "hook_done"))
                @test success(process)
                @test isempty(take!(errors))
            finally
                write(joinpath(dir, "release"), "release")
                process_running(process) && kill(process, Base.SIGKILL)
                wait(process)
            end
        end
    else
        @test_skip false # Windows console Ctrl-C is not equivalent to kill(pid, SIGINT).
    end
end

@testset failfast=true "Real direct and wrapper shutdown" begin
    mktempdir() do root
        modes = Sys.isunix() ? (:q, :eof, :sigint, :group_sigint) : (:q, :eof)
        for (index, entrypoint) in enumerate(SHUTDOWN_ENTRYPOINTS), threads in (nothing, 4), busy in (false, true), mode in modes
            dir = mkpath(joinpath(root, "$index-$threads-$busy-$mode"))
            child = start_entrypoint(entrypoint, dir, joinpath(root, "depot"); threads)
            callback, done = listen(ip"127.0.0.1", 0), listen(ip"127.0.0.1", 0)
            entered, release = joinpath(dir, "entered"), joinpath(dir, "release")
            try
                @test child.info.listener_pid == getpid(child.process)
                @test child.info.server_pid != child.info.listener_pid
                @test child.info.ready
                if Sys.isunix()
                    @test ccall(:getpgid, Cint, (Cint,), child.info.server_pid) == child.info.server_pid
                    @test ccall(:getpgid, Cint, (Cint,), child.info.listener_pid) == child.info.listener_pid
                end
                job_id, task_id = "", string(uuid4())
                if busy
                    response = listener_request(child, listener_task_payload(callback, "pause", [entered, release]; conductor=done, task_id))
                    @test startswith(response, "OK|STARTED|")
                    job_id = split(response, '|')[3]
                    @test require_shutdown_wait(() -> isfile(entered), 15, "task entry")
                    @test parse(Int, read(entered, String)) == child.info.server_pid
                end
                request_entrypoint_stop(child, mode)
                @test require_shutdown_wait(() -> listener_port_closed(child), 10, "listener admission close")
                if busy
                    @test process_running(child.process)
                    @test owned_pid_exists(child.info.server_pid) || !Sys.isunix()
                    # Repeated terminal requests must not interrupt the drain.
                    mode in (:sigint, :group_sigint) && request_entrypoint_stop(child, mode)
                    write(release, "release")
                    result = receive_listener_callback(callback)
                    terminal = receive_listener_callback(done; ack=true)
                    @test result == ["TASK_RESULT", task_id, job_id, "OK", "released,$(child.info.server_pid)"]
                    @test terminal[1:3] == ["DONE", task_id, job_id]
                    @test terminal[6] == "OK"
                    @test terminal[9] == "true"
                end
                @test require_shutdown_wait(() -> process_exited(child.process), 15, "listener exit")
                wait(child.process)
                interrupted = mode in (:sigint, :group_sigint)
                @test child.process.exitcode == (interrupted ? 130 : 0)
                @test child.process.termsignal == 0
                @test timedwait(() -> !owned_pid_exists(child.info.server_pid), 10; pollint=0.02) == :ok
                text = read(joinpath(dir, "stdout"), String)
                @test occursin("EXECUTOR event=stopped listener_id=$(child.info.listener_id) server_id=$(child.info.server_id) pid=$(child.info.server_pid)", text)
                interrupted && @test occursin("after interrupt", text)
                errors = read(joinpath(dir, "stderr"), String)
                normal_listener_stderr(errors) || println("SHUTDOWN_STDERR ", repr(errors))
                @test normal_listener_stderr(errors)
                rebound = listen(child.bind_ip, child.port)
                @test isopen(rebound)
                close(rebound)
                println("SHUTDOWN entrypoint=$(basename(entrypoint)) threads=$threads busy=$busy mode=$mode parent=$(child.info.listener_pid) child=$(child.info.server_pid) port=$(child.port)")
            finally
                close(callback)
                close(done)
                cleanup_entrypoint(child, release)
            end
        end
    end
end

@testset "Idle executor exits after owned parent dies" begin
    if Sys.isunix()
        mktempdir() do dir
            child = start_entrypoint(last(SHUTDOWN_ENTRYPOINTS), dir, joinpath(dir, "depot"))
            try
                kill(child.process, Base.SIGKILL)
                @test require_shutdown_wait(() -> process_exited(child.process), 10, "killed parent exit")
                wait(child.process)
                @test child.process.termsignal == Base.SIGKILL
                @test timedwait(() -> !owned_pid_exists(child.info.server_pid), 15; pollint=0.02) == :ok
                @test normal_listener_stderr(read(joinpath(dir, "stderr"), String))
                rebound = listen(child.bind_ip, child.port)
                @test isopen(rebound)
                close(rebound)
            finally
                cleanup_entrypoint(child, joinpath(dir, "release"))
            end
        end
    else
        @test_skip false # This failure injection relies on Unix PID/SIGKILL semantics.
    end
end
