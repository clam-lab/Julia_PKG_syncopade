using UUIDs
using Sockets
if !isdefined(@__MODULE__, :ExecutorProtocol)
    include("syncopadeExecutorProtocol.jl")
end
using .ExecutorProtocol

"""Listener-owned state. All mutations use `mutex`; no IO is performed under it."""
mutable struct ServerRuntime
    mutex::ReentrantLock
    listener_id::String
    server_id::String
    state::Symbol
    job_id::String
    control_id::String
    stop_requested::Bool
end

ServerRuntime() = ServerRuntime(ReentrantLock(), string(uuid4()), string(uuid4()), :starting, "", "", false)

runtime_snapshot_unlocked(runtime::ServerRuntime) = (
    listener_id=runtime.listener_id, server_id=runtime.server_id,
    state=runtime.state, job_id=runtime.job_id, control_id=runtime.control_id, stop_requested=runtime.stop_requested,
)
runtime_snapshot(runtime::ServerRuntime) = lock(() -> runtime_snapshot_unlocked(runtime), runtime.mutex)
runtime_ids_match(runtime, listener_id, server_id) =
    runtime.listener_id == listener_id && runtime.server_id == server_id

function runtime_mark_ready!(runtime::ServerRuntime, listener_id::String, server_id::String)::Bool
    lock(runtime.mutex) do
        runtime_ids_match(runtime, listener_id, server_id) || return false
        runtime.stop_requested && return false
        runtime.state in (:starting, :restarting) || return false
        isempty(runtime.job_id) && isempty(runtime.control_id) || return false
        runtime.state = :idle
        return true
    end
end

function runtime_reserve_job!(runtime::ServerRuntime, job_id::String)
    isempty(job_id) && throw(ArgumentError("job_id must not be empty"))
    lock(runtime.mutex) do
        runtime.state == :idle && !runtime.stop_requested || return nothing
        runtime.state = :busy
        runtime.job_id = job_id
        return runtime_snapshot_unlocked(runtime)
    end
end

function runtime_reserve_restart!(runtime::ServerRuntime, listener_id::String, server_id::String)::Symbol
    lock(runtime.mutex) do
        runtime_ids_match(runtime, listener_id, server_id) || return :id_mismatch
        !runtime.stop_requested && isempty(runtime.job_id) && isempty(runtime.control_id) && runtime.state in (:idle, :unavailable) || return :busy
        runtime.state = :restarting
        return :accepted
    end
end

function runtime_replace_server_id!(runtime::ServerRuntime, listener_id::String, server_id::String)
    lock(runtime.mutex) do
        runtime_ids_match(runtime, listener_id, server_id) || return nothing
        runtime.state == :restarting && isempty(runtime.job_id) && isempty(runtime.control_id) && !runtime.stop_requested || return nothing
        runtime.server_id = string(uuid4())
        return runtime_snapshot_unlocked(runtime)
    end
end

function runtime_finish_job!(runtime::ServerRuntime, listener_id::String, server_id::String, job_id::String)::Bool
    lock(runtime.mutex) do
        runtime_ids_match(runtime, listener_id, server_id) || return false
        !isempty(job_id) && runtime.job_id == job_id || return false
        runtime.state in (:busy, :unavailable) || return false
        runtime.job_id = ""
        if runtime.stop_requested
            runtime.state = :stopping
        elseif runtime.state == :busy
            runtime.state = :idle
        end
        return true
    end
end

function runtime_mark_unavailable!(runtime::ServerRuntime, listener_id::String, server_id::String)::Bool
    lock(runtime.mutex) do
        runtime_ids_match(runtime, listener_id, server_id) || return false
        runtime.state == :stopping && return false
        runtime.state = :unavailable
        return true
    end
end

function runtime_request_stop!(runtime::ServerRuntime)
    lock(runtime.mutex) do
        runtime.stop_requested = true
        isempty(runtime.job_id) && (runtime.state = :stopping)
        return runtime_snapshot_unlocked(runtime)
    end
end

function runtime_job_is_current(runtime::ServerRuntime, reservation)::Bool
    lock(runtime.mutex) do
        return runtime_ids_match(runtime, reservation.listener_id, reservation.server_id) &&
            !isempty(reservation.job_id) && runtime.job_id == reservation.job_id && runtime.state in (:busy, :unavailable)
    end
end

function runtime_reserve_cache_clear!(runtime::ServerRuntime)
    lock(runtime.mutex) do
        runtime.state == :idle && !runtime.stop_requested || return nothing
        runtime.state = :busy
        runtime.control_id = string(uuid4())
        return runtime_snapshot_unlocked(runtime)
    end
end

function runtime_finish_cache_clear!(runtime::ServerRuntime, reservation)::Bool
    lock(runtime.mutex) do
        runtime_ids_match(runtime, reservation.listener_id, reservation.server_id) || return false
        !isempty(reservation.control_id) && runtime.control_id == reservation.control_id || return false
        runtime.control_id = ""
        if runtime.stop_requested
            runtime.state = :stopping
        elseif runtime.state == :busy
            runtime.state = :idle
        end
        return true
    end
end

runtime_public_state(runtime::ServerRuntime) = begin
    state = runtime_snapshot(runtime).state
    state == :idle ? :idle : state == :unavailable ? :down : :busy
end

function executor_timeout_setting(name::String, default::Float64)
    value = tryparse(Float64, get(ENV, name, string(default)))
    value !== nothing && isfinite(value) && value > 0 || throw(ArgumentError("$name must be positive finite seconds"))
    return value
end

struct ExecutorLaunchConfig
    project::String
    cwd::String
    env::Dict{String,String}
    threads::String
    script::String
    startup_timeout::Float64
    shutdown_timeout::Float64
    cleanup_timeout::Float64
end

function ExecutorLaunchConfig(;
    project=dirname(something(Base.active_project(), joinpath(@__DIR__, "Project.toml"))),
    cwd=pwd(), env=copy(ENV),
    threads="$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))",
    script=joinpath(@__DIR__, "scripts", "run_executor.jl"),
    startup_timeout=executor_timeout_setting("SYNCOPADE_EXECUTOR_STARTUP_TIMEOUT", 30.0),
    shutdown_timeout=executor_timeout_setting("SYNCOPADE_EXECUTOR_SHUTDOWN_TIMEOUT", 10.0),
    cleanup_timeout=executor_timeout_setting("SYNCOPADE_EXECUTOR_CLEANUP_TIMEOUT", 2.0),
)
    all(value -> isfinite(value) && value > 0, (startup_timeout, shutdown_timeout, cleanup_timeout)) ||
        throw(ArgumentError("executor control deadlines must be positive finite seconds"))
    return ExecutorLaunchConfig(abspath(project), abspath(cwd), Dict{String,String}(env), String(threads), abspath(script),
        Float64(startup_timeout), Float64(shutdown_timeout), Float64(cleanup_timeout))
end

mutable struct ExecutorHandle
    listener_id::String
    server_id::String
    process::Base.Process
    socket::TCPSocket
    pid::Int
    julia_version::String
    syncopade_version::String
    rpc_lock::ReentrantLock
    expected_exit::Bool
    monitor::Union{Nothing,Task}
end

mutable struct ExecutorSupervisor
    runtime::ServerRuntime
    config::ExecutorLaunchConfig
    child::Union{Nothing,ExecutorHandle}
    pending_process::Union{Nothing,Base.Process}
    lifecycle_lock::ReentrantLock
    audit::IO
    output::IO
    errors::IO
end

ExecutorSupervisor(runtime::ServerRuntime; config=ExecutorLaunchConfig(), audit=stdout, output=stdout, errors=stderr) =
    ExecutorSupervisor(runtime, config, nothing, nothing, ReentrantLock(), audit, output, errors)

function executor_audit(supervisor::ExecutorSupervisor, event::String, snapshot; pid=0, reason="")
    println(supervisor.audit, "EXECUTOR event=$event listener_id=$(snapshot.listener_id) server_id=$(snapshot.server_id) pid=$pid reason=$(repr(reason))")
    flush(supervisor.audit)
end

function monitor_executor_exit!(supervisor::ExecutorSupervisor, child::ExecutorHandle)
    child.monitor = @async begin
        wait(child.process)
        unexpected = lock(supervisor.runtime.mutex) do
            if !child.expected_exit && supervisor.child === child &&
                runtime_ids_match(supervisor.runtime, child.listener_id, child.server_id)
                runtime_mark_unavailable!(supervisor.runtime, child.listener_id, child.server_id)
                return true
            end
            return false
        end
        unexpected && close(child.socket)
        executor_audit(supervisor, "exited", child; pid=child.pid,
            reason="unexpected=$unexpected exit=$(child.process.exitcode) signal=$(child.process.termsignal)")
    end
    return nothing
end

struct ExecutorControlTimeout <: Exception
    operation::String
end
Base.showerror(io::IO, error::ExecutorControlTimeout) = print(io, "executor control timeout: ", error.operation)

function executor_exchange(child::ExecutorHandle, message::ExecutorMessage, expected_kind::String; timeout=nothing)
    lock(child.rpc_lock) do
        expired = Ref(false)
        timer = timeout === nothing ? nothing : Timer(Float64(timeout)) do _
            expired[] = true
            close(child.socket)
        end
        try
            expect_executor_message(message, message.kind, child.listener_id, child.server_id, message.request_id)
            write_executor_message(child.socket, message)
            reply = read_executor_message(child.socket)
            return expect_executor_message(reply, expected_kind, child.listener_id, child.server_id, message.request_id)
        catch
            expired[] && throw(ExecutorControlTimeout(message.kind))
            rethrow()
        finally
            timer === nothing || close(timer)
        end
    end
end

function wait_executor_exit(process::Base.Process, timeout::Real)::Bool
    timedwait(() -> process_exited(process), timeout; pollint=min(0.01, timeout / 10)) == :ok || return false
    wait(process)
    return true
end

"""Reap only this supervisor's process; report inability to confirm exit."""
function reap_failed_executor!(process::Base.Process, timeout::Real)::Bool
    process_exited(process) && (wait(process); return true)
    try
        kill(process)
    catch
        process_exited(process) || rethrow()
    end
    wait_executor_exit(process, timeout) && return true
    try
        kill(process, Base.SIGKILL)
    catch
        process_exited(process) || rethrow()
    end
    return wait_executor_exit(process, timeout)
end

function launch_executor!(supervisor::ExecutorSupervisor)
    lock(supervisor.lifecycle_lock) do
        snapshot = runtime_snapshot(supervisor.runtime)
        snapshot.state in (:starting, :restarting) && !snapshot.stop_requested && isempty(snapshot.job_id) && isempty(snapshot.control_id) ||
            return (ok=false, reason=:busy, message="runtime is not awaiting startup", pid=0)
        supervisor.child === nothing || return (ok=false, reason=:child_present, message="previous child has not been reaped", pid=supervisor.child.pid)
        supervisor.pending_process === nothing || return (ok=false, reason=:child_present, message="startup child has not been reaped", pid=getpid(supervisor.pending_process))
        config = supervisor.config
        listener = listen(ip"127.0.0.1", 0)
        process = nothing
        socket = nothing
        timer = nothing
        expired = Ref(false)
        accepted = false
        pid = 0
        executor_audit(supervisor, "starting", snapshot; reason="control_port=$(getsockname(listener)[2])")
        try
            port = getsockname(listener)[2]
            command = `$(Base.julia_cmd()) --startup-file=no --project=$(config.project) --threads=$(config.threads) $(config.script) $port $(snapshot.listener_id) $(snapshot.server_id)`
            command = Cmd(command; dir=config.cwd, env=config.env)
            process = run(pipeline(command; stdin=devnull, stdout=supervisor.output, stderr=supervisor.errors); wait=false)
            supervisor.pending_process = process
            pid = getpid(process)
            timer = Timer(config.startup_timeout) do _
                expired[] = true
                close(listener)
                socket === nothing || close(socket)
            end
            socket = accept(listener)
            close(listener)
            ready = expect_executor_message(read_executor_message(socket), "READY", snapshot.listener_id, snapshot.server_id, "")
            parse(Int, ready.data[1]) == pid || throw(ArgumentError("READY PID does not match owned child"))
            process_running(process) || throw(ArgumentError("child exited before READY acceptance"))
            child = ExecutorHandle(snapshot.listener_id, snapshot.server_id, process, socket, pid,
                ready.data[2], ready.data[3], ReentrantLock(), false, nothing)
            lock(supervisor.runtime.mutex) do
                runtime_mark_ready!(supervisor.runtime, snapshot.listener_id, snapshot.server_id) ||
                    throw(ArgumentError("runtime changed before READY acceptance"))
                supervisor.child = child
                supervisor.pending_process = nothing
            end
            monitor_executor_exit!(supervisor, child)
            accepted = true
            executor_audit(supervisor, "ready", snapshot; pid)
            return (ok=true, reason=:ready, message="", pid)
        catch error
            reason = expired[] ? :startup_timeout : :startup_failed
            if process !== nothing && process_exited(process)
                reason = :startup_failed
            end
            socket === nothing || close(socket)
            reaped = process === nothing || reap_failed_executor!(process, config.cleanup_timeout)
            reaped && (supervisor.pending_process = nothing)
            runtime_mark_unavailable!(supervisor.runtime, snapshot.listener_id, snapshot.server_id)
            message = sprint(showerror, error)
            executor_audit(supervisor, "startup_failed", snapshot; pid, reason=string(reason, ": ", message, "; reaped=", reaped))
            return (ok=false, reason=reaped ? reason : :cleanup_failed, message, pid)
        finally
            timer === nothing || close(timer)
            close(listener)
            !accepted && socket !== nothing && close(socket)
        end
    end
end

function stop_executor!(supervisor::ExecutorSupervisor)
    lock(supervisor.lifecycle_lock) do
        snapshot = runtime_snapshot(supervisor.runtime)
        isempty(snapshot.job_id) && isempty(snapshot.control_id) && snapshot.state in (:starting, :restarting, :unavailable, :stopping) ||
            return (ok=false, reason=:busy, message="runtime not reserved for shutdown", pid=0)
        child = supervisor.child
        if supervisor.pending_process !== nothing
            process = supervisor.pending_process
            pid = getpid(process)
            reaped = reap_failed_executor!(process, supervisor.config.cleanup_timeout)
            reaped && (supervisor.pending_process = nothing)
            return (ok=reaped, reason=reaped ? :stopped : :cleanup_failed, message="startup process cleanup", pid)
        end
        child === nothing && return (ok=true, reason=:already_stopped, message="", pid=0)
        config = supervisor.config
        executor_audit(supervisor, "stopping", child; pid=child.pid)
        lock(supervisor.runtime.mutex) do
            child.expected_exit = true
        end
        try
            if !process_exited(child.process)
                id = string(uuid4())
                executor_exchange(child, ExecutorMessage("STOP", child.listener_id, child.server_id, id, String[]), "STOPPED";
                    timeout=config.shutdown_timeout)
                wait_executor_exit(child.process, config.shutdown_timeout) || throw(ExecutorControlTimeout("process exit"))
            else
                wait(child.process)
            end
            close(child.socket)
            child.monitor === nothing || wait(child.monitor)
            supervisor.child = nothing
            executor_audit(supervisor, "stopped", child; pid=child.pid)
            return (ok=true, reason=:stopped, message="", pid=child.pid)
        catch error
            close(child.socket)
            reaped = reap_failed_executor!(child.process, config.cleanup_timeout)
            reaped && child.monitor !== nothing && wait(child.monitor)
            reaped && (supervisor.child = nothing)
            runtime_mark_unavailable!(supervisor.runtime, child.listener_id, child.server_id)
            message = sprint(showerror, error)
            executor_audit(supervisor, "stop_failed", child; pid=child.pid, reason=string(message, "; reaped=", reaped))
            return (ok=false, reason=reaped ? :stop_failed : :cleanup_failed, message, pid=child.pid)
        end
    end
end
