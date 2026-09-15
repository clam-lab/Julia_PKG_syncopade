using Test
include(joinpath(@__DIR__, "..", "syncopadeServer.jl"))

const RELOAD_FIXTURE = joinpath(@__DIR__, "fixtures", "package_reload")
const RELOAD_PROJECT = dirname(@__DIR__)

function reload_call(path, name)
    # Replacing the task module is intentional; only suppress that known warning.
    result, warnings = mktemp() do _, io
        value = redirect_stderr(io) do
            call_func(path, name, "run")
        end
        flush(io)
        seekstart(io)
        (value, read(io, String))
    end
    @test all(line -> occursin(r"^WARNING: replacing module (StandaloneTask|PackageTask)\.$", line),
              split(warnings, '\n'; keepempty=false))
    return result
end

loaded_module(name) = Base.invokelatest(getfield, Main, Symbol(name))
dependency(mod) = Base.invokelatest(getfield, mod, :ReloadProbe)

function run_reload_case(mode)
    mktempdir() do dir
        withenv("SYNCOPADE_MOUNT_ROOT_UNIX" => dir,
                "SYNCOPADE_MOUNT_ROOT_WINDOWS" => dir,
                "SYNCOPADE_FUNCTION_CACHE_SIZE" => "10") do
            if mode == "task"
                task = joinpath(dir, "task.jl")
                cp(joinpath(RELOAD_FIXTURE, "task_v1.jl"), task)
                @test reload_call(task, "StandaloneTask") == "V1"
                old_module = loaded_module("StandaloneTask")
                cp(joinpath(RELOAD_FIXTURE, "task_v2.jl"), task; force=true)
                @test reload_call(task, "StandaloneTask") == "V1"
                @test loaded_module("StandaloneTask") === old_module
                @test clear_function_cache!() == 1
                @test reload_call(task, "StandaloneTask") == "V2"
                @test loaded_module("StandaloneTask") !== old_module
                return
            end
            first_root = joinpath(dir, "first")
            second_root = joinpath(dir, "second")
            cp(joinpath(RELOAD_FIXTURE, "v1"), first_root)
            cp(joinpath(RELOAD_FIXTURE, "v2"), second_root)
            task = joinpath(first_root, "task.jl")
            cp(joinpath(RELOAD_FIXTURE, "package_task.jl"), task)
            pushfirst!(LOAD_PATH, first_root)
            first = split(reload_call(task, "PackageTask"), '|')
            old_module = loaded_module("PackageTask")
            old_package = dependency(old_module)
            @test first[1] == "V1"
            @test parse(Int, first[2]) == getpid()
            @test first[3] == joinpath(first_root, "ReloadProbe", "src", "ReloadProbe.jl")
            if mode == "overwrite"
                cp(joinpath(second_root, "ReloadProbe", "src", "ReloadProbe.jl"), first[3]; force=true)
                next_root = first_root
            else
                @test mode == "switch"
                next_root = second_root
                task = joinpath(next_root, "task.jl")
                cp(joinpath(RELOAD_FIXTURE, "package_task.jl"), task)
                pushfirst!(LOAD_PATH, next_root)
            end
            @test clear_function_cache!() == 1
            second = split(reload_call(task, "PackageTask"), '|')
            @test second == first
            @test loaded_module("PackageTask") !== old_module
            @test dependency(loaded_module("PackageTask")) === old_package
            @test string(Base.PkgId(old_package).uuid) == "8912d8c9-86d7-40fa-95e8-df24bb3f1c1a"
            command = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=no --project=$RELOAD_PROJECT $(@__FILE__) fresh $next_root $task`
            fresh = split(strip(read(command, String)), '|')
            @test fresh[1] == "V2"
            @test parse(Int, fresh[2]) != getpid()
            @test fresh[3] == joinpath(next_root, "ReloadProbe", "src", "ReloadProbe.jl")
            println("RELOAD_EVIDENCE mode=$mode old_pid=$(first[2]) new_pid=$(fresh[2]) same_process=$(second[1]) fresh=$(fresh[1])")
        end
    end
end

if isempty(ARGS)
    @testset "Package reload boundary subprocesses" begin
        for mode in ("task", "overwrite", "switch")
            command = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=no --project=$RELOAD_PROJECT $(@__FILE__) $mode`
            process = run(ignorestatus(command))
            @test process.exitcode == 0
        end
    end
elseif ARGS[1] == "fresh"
    pushfirst!(LOAD_PATH, ARGS[2])
    println(call_func(ARGS[3], "PackageTask", "run"))
else
    @testset "Package reload $(ARGS[1])" begin
        run_reload_case(ARGS[1])
    end
end
