using UUIDs

"""Listener-owned state. All mutations use `mutex`; no IO is performed under it."""
mutable struct ServerRuntime
    mutex::ReentrantLock
    listener_id::String
    server_id::String
    state::Symbol
    job_id::String
    stop_requested::Bool
end

ServerRuntime() = ServerRuntime(ReentrantLock(), string(uuid4()), string(uuid4()), :starting, "", false)

runtime_snapshot_unlocked(runtime::ServerRuntime) = (
    listener_id=runtime.listener_id, server_id=runtime.server_id,
    state=runtime.state, job_id=runtime.job_id, stop_requested=runtime.stop_requested,
)
runtime_snapshot(runtime::ServerRuntime) = lock(() -> runtime_snapshot_unlocked(runtime), runtime.mutex)
runtime_ids_match(runtime, listener_id, server_id) =
    runtime.listener_id == listener_id && runtime.server_id == server_id

function runtime_mark_ready!(runtime::ServerRuntime, listener_id::String, server_id::String)::Bool
    lock(runtime.mutex) do
        runtime_ids_match(runtime, listener_id, server_id) || return false
        runtime.stop_requested && return false
        runtime.state in (:starting, :restarting) || return false
        isempty(runtime.job_id) || return false
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
        !runtime.stop_requested && isempty(runtime.job_id) && runtime.state in (:idle, :unavailable) || return :busy
        runtime.state = :restarting
        return :accepted
    end
end

function runtime_replace_server_id!(runtime::ServerRuntime, listener_id::String, server_id::String)
    lock(runtime.mutex) do
        runtime_ids_match(runtime, listener_id, server_id) || return nothing
        runtime.state == :restarting && isempty(runtime.job_id) && !runtime.stop_requested || return nothing
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

runtime_public_state(runtime::ServerRuntime) = begin
    state = runtime_snapshot(runtime).state
    state == :idle ? :idle : state == :unavailable ? :down : :busy
end
