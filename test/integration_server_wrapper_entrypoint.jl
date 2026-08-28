using Sockets
using Test

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

const SERVER_WRAPPER_REPOSITORY_ROOT = normpath(joinpath(@__DIR__, ".."))
const SERVER_WRAPPER_SCRIPT = joinpath(
    SERVER_WRAPPER_REPOSITORY_ROOT,
    "scripts",
    "run_server.jl",
)
const SERVER_SOURCE = joinpath(SERVER_WRAPPER_REPOSITORY_ROOT, "syncopadeServer.jl")
const SERVER_WRAPPER_REPOSITORY_LOG = joinpath(
    SERVER_WRAPPER_REPOSITORY_ROOT,
    "logs",
    "conductor_events.csv",
)

function server_wrapper_parse_int(args::Vector{String}, index::Int, default::Int)::Int
    return length(args) >= index ? parse(Int, args[index]) : default
end

function server_wrapper_parse_float(
    args::Vector{String},
    index::Int,
    default::Float64,
)::Float64
    return length(args) >= index ? parse(Float64, args[index]) : default
end

function server_wrapper_file_bytes_or_nothing(path::String)
    return isfile(path) ? read(path) : nothing
end

function server_wrapper_assert_port_free(ip::String, port::Int)::Nothing
    listener = listen(IPv4(ip), port)
    close(listener)
    return nothing
end

function server_wrapper_wait_for_exit(process::Base.Process, timeout::Float64)::Bool
    result = Base.timedwait(() -> process_exited(process), timeout; pollint=0.02)
    return result !== :timed_out
end

function server_wrapper_wait_for_status(
    process::Base.Process,
    server_ip::String,
    server_port::Int,
    timeout::Float64,
)::String
    deadline = time() + timeout
    last_error = "none"
    while time() < deadline
        process_exited(process) &&
            error("wrapper exited before STATUS readiness: exit=$(process.exitcode)")
        try
            response = query_server_status(server_ip, server_port)
            response == "STATUS|idle" || error("unexpected STATUS response: $response")
            return response
        catch e
            last_error = sprint(showerror, e)
            sleep(0.05)
        end
    end
    error("timeout waiting for server STATUS response: $last_error")
end

function server_wrapper_launch_child(
    script_path::String,
    case_label::String,
    artifact_dir::String,
)::NamedTuple
    stdout_path = joinpath(artifact_dir, case_label * ".stdout")
    stderr_path = joinpath(artifact_dir, case_label * ".stderr")
    stdout_io = open(stdout_path, "w")
    stderr_io = open(stderr_path, "w")

    command = `$(Base.julia_cmd()) --project=$(SERVER_WRAPPER_REPOSITORY_ROOT) $script_path`
    command = addenv(
        command,
        "SYNCOPADE_NODE_PROFILE" => "lan100",
        "SYNCOPADE_WIRED_PREFIX" => "192.168.100.",
    )
    redirected_command = pipeline(command; stderr=stderr_io)

    process = try
        open(redirected_command, "w", stdout_io)
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
    )
end

function server_wrapper_close_output!(child::NamedTuple)::Nothing
    isopen(child.stdout_io) && close(child.stdout_io)
    isopen(child.stderr_io) && close(child.stderr_io)
    return nothing
end

function server_wrapper_close_stdin!(child::NamedTuple)::Nothing
    try
        closewrite(child.process)
    catch e
        e isa Base.IOError || rethrow()
    end
    return nothing
end

function server_wrapper_stop_with_q!(child::NamedTuple, timeout::Float64)::Nothing
    process_exited(child.process) && error("wrapper exited before q cleanup")
    write(child.process, "q\n")
    flush(child.process)
    server_wrapper_close_stdin!(child)
    server_wrapper_wait_for_exit(child.process, timeout) ||
        error("wrapper did not exit after q within $timeout seconds")
    wait(child.process)
    server_wrapper_close_output!(child)
    return nothing
end

function server_wrapper_force_cleanup!(child::NamedTuple, timeout::Float64)::Nothing
    try
        server_wrapper_close_stdin!(child)
        if !process_exited(child.process)
            kill(child.process, Base.SIGKILL)
            server_wrapper_wait_for_exit(child.process, timeout) ||
                error("wrapper did not exit after SIGKILL")
        end
        wait(child.process)
    finally
        server_wrapper_close_output!(child)
    end
    return nothing
end

function server_wrapper_finish_exited!(child::NamedTuple)::Nothing
    server_wrapper_close_stdin!(child)
    wait(child.process)
    server_wrapper_close_output!(child)
    return nothing
end

function server_wrapper_entrypoint_main(args::Vector{String}=ARGS)::Nothing
    server_ip = length(args) >= 1 ? args[1] : "192.168.100.30"
    server_port = server_wrapper_parse_int(args, 2, 8030)
    timeout = server_wrapper_parse_float(args, 3, 5.0)
    (isfinite(timeout) && timeout > 0) || error("timeout must be finite and > 0")

    artifact_dir = mktempdir(; prefix="syncopade-server-wrapper-", cleanup=false)
    repository_log_before =
        server_wrapper_file_bytes_or_nothing(SERVER_WRAPPER_REPOSITORY_LOG)
    println("artifact_dir=$artifact_dir")

    server_wrapper_assert_port_free(server_ip, server_port)

    positive = server_wrapper_launch_child(
        SERVER_WRAPPER_SCRIPT,
        "positive",
        artifact_dir,
    )
    positive_completed = false
    status_response = ""
    runtime_stderr_bytes = -1
    try
        status_response = server_wrapper_wait_for_status(
            positive.process,
            server_ip,
            server_port,
            timeout,
        )
        process_exited(positive.process) && error("wrapper exited after STATUS response")
        runtime_stderr_bytes = filesize(positive.stderr_path)
        runtime_stderr_bytes == 0 || error("wrapper emitted runtime stderr")
        server_wrapper_stop_with_q!(positive, timeout)
        positive_completed = true
    finally
        positive_completed || server_wrapper_force_cleanup!(positive, timeout)
    end

    @test positive.process.exitcode == 0
    @test positive.process.termsignal == 0
    @test occursin(
        "bind address: $(server_ip):$(server_port)",
        read(positive.stdout_path, String),
    )
    @test filesize(positive.stderr_path) == 0
    server_wrapper_assert_port_free(server_ip, server_port)

    negative_script = joinpath(artifact_dir, "include_only_wrapper.jl")
    open(negative_script, "w") do io
        println(io, "include(", repr(SERVER_SOURCE), ")")
    end

    negative = server_wrapper_launch_child(negative_script, "negative", artifact_dir)
    negative_completed = false
    try
        server_wrapper_wait_for_exit(negative.process, timeout) ||
            error("include-only negative fixture did not exit")
        server_wrapper_finish_exited!(negative)
        negative_completed = true
    finally
        negative_completed || server_wrapper_force_cleanup!(negative, timeout)
    end

    @test negative.process.exitcode == 0
    @test negative.process.termsignal == 0
    @test filesize(negative.stdout_path) == 0
    @test filesize(negative.stderr_path) == 0
    server_wrapper_assert_port_free(server_ip, server_port)

    repository_log_after =
        server_wrapper_file_bytes_or_nothing(SERVER_WRAPPER_REPOSITORY_LOG)
    @test repository_log_after == repository_log_before

    println("STEP3_RESULT=PASS_SERVER_WRAPPER_ENTRYPOINT_REGRESSION")
    println("status_response=$status_response")
    println("positive_runtime_stderr_bytes=$runtime_stderr_bytes")
    println("positive_exit_code=$(positive.process.exitcode)")
    println("positive_termsignal=$(positive.process.termsignal)")
    println("negative_exit_code=$(negative.process.exitcode)")
    println("negative_termsignal=$(negative.process.termsignal)")
    println("final_port_free=true")
    println("repository_log_unchanged=true")
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    server_wrapper_entrypoint_main()
end
