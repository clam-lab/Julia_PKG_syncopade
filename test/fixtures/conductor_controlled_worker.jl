module ConductorControlledWorker

using Sockets

export ControlledWorker,
    respond_job!,
    respond_status!,
    start_controlled_worker,
    stop_controlled_worker!,
    wait_for_request,
    worker_history

const ALLOWED_STATUS_RESPONSES = Set(["STATUS|idle", "STATUS|busy"])

mutable struct ControlledWorker
    ip::IPv4
    port::Int
    listener::Sockets.TCPServer
    request_events::Channel{NamedTuple}
    status_responses::Channel{String}
    job_responses::Channel{String}
    history::Vector{NamedTuple}
    history_lock::ReentrantLock
    next_request_id::Base.RefValue{Int}
    stopping::Base.RefValue{Bool}
    connection_tasks::Vector{Task}
    accept_task::Union{Nothing,Task}
end

function checksum_hex(payload::String)::String
    value = UInt8(0)
    for byte in codeunits(payload)
        value ⊻= byte
    end
    return lowercase(string(value; base=16, pad=2))
end

function decode_request(line::String)::String
    fields = split(chomp(line), '|')
    length(fields) >= 2 || throw(ArgumentError("request lacks checksum: $line"))
    received_checksum = String(fields[end])
    payload = join(fields[1:(end - 1)], '|')
    received_checksum == checksum_hex(payload) ||
        throw(ArgumentError("invalid request checksum: $line"))
    return payload
end

function record_history!(
    worker::ControlledWorker,
    event::Symbol,
    request_id::Int,
    kind::Symbol,
    value::String,
)::NamedTuple
    entry = (
        event=event,
        request_id=request_id,
        kind=kind,
        value=value,
        recorded_ns=time_ns(),
    )
    lock(worker.history_lock) do
        push!(worker.history, entry)
    end
    return entry
end

function next_request_id!(worker::ControlledWorker)::Int
    lock(worker.history_lock) do
        worker.next_request_id[] += 1
        return worker.next_request_id[]
    end
end

function handle_connection(worker::ControlledWorker, socket::Sockets.TCPSocket)::Nothing
    try
        payload = decode_request(readline(socket))
        kind = payload == "STATUS" ? :status : :job
        request_id = next_request_id!(worker)
        request = record_history!(worker, :request, request_id, kind, payload)
        put!(worker.request_events, request)

        response = if kind == :status
            take!(worker.status_responses)
        else
            take!(worker.job_responses)
        end
        println(socket, response)
        record_history!(worker, :response, request_id, kind, response)
        return nothing
    catch
        worker.stopping[] || rethrow()
        return nothing
    finally
        try
            close(socket)
        catch
        end
    end
end

function run_accept_loop(worker::ControlledWorker)::Nothing
    try
        while !worker.stopping[]
            socket = accept(worker.listener)
            connection_task = @async handle_connection(worker, socket)
            lock(worker.history_lock) do
                push!(worker.connection_tasks, connection_task)
            end
        end
    catch
        worker.stopping[] || rethrow()
    end
    return nothing
end

function start_controlled_worker()::ControlledWorker
    bind_ip = IPv4("127.0.0.1")
    listener = listen(bind_ip, 0)
    _, port_unsigned = getsockname(listener)
    worker = ControlledWorker(
        bind_ip,
        Int(port_unsigned),
        listener,
        Channel{NamedTuple}(64),
        Channel{String}(64),
        Channel{String}(64),
        NamedTuple[],
        ReentrantLock(),
        Ref(0),
        Ref(false),
        Task[],
        nothing,
    )
    worker.accept_task = @async run_accept_loop(worker)
    return worker
end

function wait_for_request(
    worker::ControlledWorker,
    expected_kind::Symbol;
    timeout::Float64=2.0,
)::NamedTuple
    expected_kind in (:status, :job) ||
        throw(ArgumentError("expected_kind must be :status or :job"))
    wait_result = Base.timedwait(
        () -> isready(worker.request_events),
        timeout;
        pollint=min(0.01, timeout),
    )
    wait_result === :timed_out &&
        error("timeout waiting controlled worker request kind=$expected_kind")
    request = take!(worker.request_events)
    request.kind == expected_kind ||
        error("unexpected controlled worker request kind=$(request.kind), expected=$expected_kind")
    return request
end

function respond_status!(worker::ControlledWorker, response::String)::Nothing
    response in ALLOWED_STATUS_RESPONSES ||
        throw(ArgumentError("unsupported STATUS response: $response"))
    put!(worker.status_responses, response)
    return nothing
end

function respond_job!(worker::ControlledWorker, response::String)::Nothing
    valid = response == "ERROR|BUSY" || startswith(response, "OK|STARTED|")
    valid || throw(ArgumentError("unsupported job response: $response"))
    if startswith(response, "OK|STARTED|")
        fields = split(response, '|')
        length(fields) == 3 && !isempty(fields[3]) ||
            throw(ArgumentError("job ID is missing from response: $response"))
    end
    put!(worker.job_responses, response)
    return nothing
end

function worker_history(worker::ControlledWorker)::Vector{NamedTuple}
    return lock(worker.history_lock) do
        copy(worker.history)
    end
end

function wait_for_task(task::Task, timeout::Float64, label::String)::Nothing
    wait_result = Base.timedwait(() -> istaskdone(task), timeout; pollint=min(0.01, timeout))
    wait_result === :timed_out && error("timeout waiting for $label")
    fetch(task)
    return nothing
end

function stop_controlled_worker!(worker::ControlledWorker; timeout::Float64=2.0)::Nothing
    worker.stopping[] = true
    try
        close(worker.listener)
    catch
    end
    isopen(worker.status_responses) && close(worker.status_responses)
    isopen(worker.job_responses) && close(worker.job_responses)

    accept_task = worker.accept_task
    accept_task === nothing || wait_for_task(accept_task, timeout, "controlled worker accept task")

    tasks = lock(worker.history_lock) do
        copy(worker.connection_tasks)
    end
    for (index, task) in enumerate(tasks)
        wait_for_task(task, timeout, "controlled worker connection task $index")
    end
    return nothing
end

end
