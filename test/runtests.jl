using Test

const TEST_REPOSITORY_ROOT = normpath(joinpath(@__DIR__, ".."))
const ISOLATED_TEST_FILES = String[
    "unit_client_protocol.jl",
    "unit_conductor_queue.jl",
    "unit_conductor_node_state.jl",
    "regression_conductor_stale_idle.jl",
    "unit_conductor_dispatch_reservation.jl",
    "regression_conductor_done_identity.jl",
    "unit_controlled_worker_fixture.jl",
    "regression_conductor_busy_wait.jl",
    "unit_conductor_task_lifecycle.jl",
    "regression_conductor_queue_deadline.jl",
    "regression_conductor_dispatch_timeout.jl",
    "unit_result_protocol.jl",
    "unit_server_admission_state.jl",
    "regression_conductor_terminal_callback.jl",
    "unit_conductor_terminal_callback.jl",
]

function run_isolated_test(test_file::String, artifact_dir::String)::NamedTuple
    test_path = joinpath(@__DIR__, test_file)
    test_name = splitext(basename(test_file))[1]
    test_artifact_dir = joinpath(artifact_dir, test_name)
    mkpath(test_artifact_dir)
    log_path = joinpath(test_artifact_dir, "conductor_events.csv")
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(TEST_REPOSITORY_ROOT) --threads=4 $test_path`
    command = addenv(
        command,
        "SYNCOPADE_CONDUCTOR_LOG" => log_path,
        "SYNCOPADE_TEST_ARTIFACT_DIR" => test_artifact_dir
    )
    stdout_buffer = IOBuffer()
    stderr_buffer = IOBuffer()
    process = run(pipeline(
        ignorestatus(command);
        stdout=stdout_buffer,
        stderr=stderr_buffer
    ))
    return (
        exit_code=process.exitcode,
        stdout=String(take!(stdout_buffer)),
        stderr=String(take!(stderr_buffer)),
    )
end

suite_artifact_dir = mktempdir(; prefix="syncopade-isolated-suite-")
try
    @testset "Syncopade isolated deterministic suite" begin
        for test_file in ISOLATED_TEST_FILES
            result = run_isolated_test(test_file, suite_artifact_dir)
            println("ISOLATED_TEST_FILE=", test_file)
            print(result.stdout)
            if !isempty(result.stderr)
                println("ISOLATED_TEST_STDERR_BEGIN=", test_file)
                print(result.stderr)
                println("ISOLATED_TEST_STDERR_END=", test_file)
            end
            @test result.exit_code == 0
            @test isempty(result.stderr)
        end
    end
finally
    rm(suite_artifact_dir; recursive=true, force=true)
end

println("ISOLATED_TEST_COUNT=", length(ISOLATED_TEST_FILES))
println("Manual lan100 integration script: test/integration_conductor_node_exclusivity.jl")
