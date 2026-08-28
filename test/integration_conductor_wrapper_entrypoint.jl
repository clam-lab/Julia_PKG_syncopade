using Sockets
using Test

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

const WRAPPER_REPOSITORY_ROOT = normpath(joinpath(@__DIR__, ".."))
const WRAPPER_SCRIPT = joinpath(WRAPPER_REPOSITORY_ROOT, "scripts", "run_conductor.jl")
const CONDUCTOR_SOURCE = joinpath(WRAPPER_REPOSITORY_ROOT, "syncopadeConductor.jl")
const REPOSITORY_CONDUCTOR_LOG = joinpath(
    WRAPPER_REPOSITORY_ROOT,
    "logs",
    "conductor_events.csv",
)

function parse_int_arg(args::Vector{String}, index::Int, default::Int)::Int
    return length(args) >= index ? parse(Int, args[index]) : default
end

function parse_float_arg(args::Vector{String}, index::Int, default::Float64)::Float64
    return length(args) >= index ? parse(Float64, args[index]) : default
end

function file_bytes_or_nothing(path::String)
    return isfile(path) ? read(path) : nothing
end

function assert_port_free(ip::String, port::Int)::Nothing
    listener = listen(IPv4(ip), port)
    close(listener)
    return nothing
end

function wait_for_exit(process::Base.Process, timeout::Float64)::Bool
    result = Base.timedwait(() -> process_exited(process), timeout; pollint=0.02)
    return result !== :timed_out
end

function wait_for_list_payload(
    process::Base.Process,
    conductor_ip::String,
    conductor_port::Int,
    timeout::Float64,
)::String
    deadline = time() + timeout
    last_error = "none"
    while time() < deadline
        process_exited(process) &&
            error("wrapper exited before LIST readiness: exit=$(process.exitcode)")
        try
            payload = query_conductor_nodes(conductor_ip; conductor_port=conductor_port)
            startswith(payload, "NODES") || error("unexpected LIST payload: $payload")
            return payload
        catch e
            last_error = sprint(showerror, e)
            sleep(0.05)
        end
    end
    error("timeout waiting for conductor LIST response: $last_error")
end

function wait_for_text(path::String, pattern::String, timeout::Float64)::Nothing
    deadline = time() + timeout
    while time() < deadline
        if isfile(path) && occursin(pattern, read(path, String))
            return nothing
        end
        sleep(0.02)
    end
    error("timeout waiting for '$pattern' in $path")
end

function launch_child(
    script_path::String,
    case_label::String,
    artifact_dir::String,
)::NamedTuple
    stdout_path = joinpath(artifact_dir, case_label * ".stdout")
    stderr_path = joinpath(artifact_dir, case_label * ".stderr")
    log_path = joinpath(artifact_dir, case_label * "_conductor.csv")
    stdout_io = open(stdout_path, "w")
    stderr_io = open(stderr_path, "w")

    command = `$(Base.julia_cmd()) --project=$(WRAPPER_REPOSITORY_ROOT) $script_path`
    command = addenv(
        command,
        "SYNCOPADE_NODE_PROFILE" => "lan100",
        "SYNCOPADE_WIRED_PREFIX" => "192.168.100.",
        "SYNCOPADE_CONDUCTOR_LOG" => log_path,
    )

    process = try
        run(pipeline(command; stdout=stdout_io, stderr=stderr_io); wait=false)
    catch
        close(stdout_io)
        close(stderr_io)
        rethrow()
    end

    return (
        process=process,
        stdout_io=stdout_io,
        stderr_io=stderr_io,
        stdout_path=stdout_path,
        stderr_path=stderr_path,
        log_path=log_path,
    )
end

function terminate_child!(
    child::NamedTuple,
    signal::Integer,
    timeout::Float64,
)::Bool
    fallback_used = false
    try
        if !process_exited(child.process)
            kill(child.process, signal)
            if !wait_for_exit(child.process, timeout)
                signal == Base.SIGKILL &&
                    error("child did not exit after SIGKILL within $timeout seconds")
                fallback_used = true
                kill(child.process, Base.SIGKILL)
                wait_for_exit(child.process, timeout) ||
                    error("child did not exit after SIGKILL fallback")
            end
        end
        wait(child.process)
    finally
        isopen(child.stdout_io) && close(child.stdout_io)
        isopen(child.stderr_io) && close(child.stderr_io)
    end
    return fallback_used
end

function wrapper_entrypoint_main(args::Vector{String}=ARGS)::Nothing
    conductor_ip = length(args) >= 1 ? args[1] : "192.168.100.30"
    conductor_port = parse_int_arg(args, 2, 9030)
    timeout = parse_float_arg(args, 3, 5.0)
    (isfinite(timeout) && timeout > 0) || error("timeout must be finite and > 0")

    artifact_dir = mktempdir(; prefix="syncopade-wrapper-entrypoint-", cleanup=false)
    repository_log_before = file_bytes_or_nothing(REPOSITORY_CONDUCTOR_LOG)
    println("artifact_dir=$artifact_dir")

    assert_port_free(conductor_ip, conductor_port)

    positive = launch_child(WRAPPER_SCRIPT, "positive", artifact_dir)
    positive_ready = false
    positive_kill_fallback = false
    list_payload = ""
    runtime_stderr_bytes = -1
    try
        list_payload = wait_for_list_payload(
            positive.process,
            conductor_ip,
            conductor_port,
            timeout,
        )
        process_exited(positive.process) && error("wrapper exited after LIST response")
        runtime_stderr_bytes = filesize(positive.stderr_path)
        runtime_stderr_bytes == 0 ||
            error("wrapper emitted runtime stderr before shutdown")
        wait_for_text(positive.log_path, "CONDUCTOR_START", timeout)
        positive_ready = true
    finally
        positive_kill_fallback = terminate_child!(
            positive,
            positive_ready ? Base.SIGTERM : Base.SIGKILL,
            timeout,
        )
    end

    @test positive.process.termsignal ==
          (positive_kill_fallback ? Base.SIGKILL : Base.SIGTERM)
    @test occursin("signal 15: Terminated", read(positive.stderr_path, String))
    assert_port_free(conductor_ip, conductor_port)

    negative_script = joinpath(artifact_dir, "include_only_wrapper.jl")
    open(negative_script, "w") do io
        println(io, "include(", repr(CONDUCTOR_SOURCE), ")")
    end

    negative = launch_child(negative_script, "negative", artifact_dir)
    negative_exited = false
    try
        negative_exited = wait_for_exit(negative.process, timeout)
        negative_exited || error("include-only negative fixture did not exit")
    finally
        terminate_child!(
            negative,
            negative_exited ? Base.SIGTERM : Base.SIGKILL,
            timeout,
        )
    end

    @test negative.process.exitcode == 0
    @test negative.process.termsignal == 0
    @test filesize(negative.stdout_path) == 0
    @test filesize(negative.stderr_path) == 0
    @test !isfile(negative.log_path)
    assert_port_free(conductor_ip, conductor_port)

    repository_log_after = file_bytes_or_nothing(REPOSITORY_CONDUCTOR_LOG)
    @test repository_log_after == repository_log_before

    println("STEP3_RESULT=PASS_WRAPPER_ENTRYPOINT_REGRESSION")
    println("list_payload=$list_payload")
    println("positive_runtime_stderr_bytes=$runtime_stderr_bytes")
    println("positive_termsignal=$(positive.process.termsignal)")
    println("positive_sigkill_fallback=$positive_kill_fallback")
    println("negative_exit_code=$(negative.process.exitcode)")
    println("negative_termsignal=$(negative.process.termsignal)")
    println("final_port_free=true")
    println("repository_log_unchanged=true")
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    wrapper_entrypoint_main()
end
