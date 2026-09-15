using Test
include(joinpath(@__DIR__, "..", "syncopadeExecutor.jl"))

@testset "Executor loading preserves cache and path contracts" begin
    @test !isdefined(Main, :server_state)
    @test isempty(function_cache)
    withenv("SYNCOPADE_FUNCTION_CACHE_SIZE" => "garbage") do
        @test configured_function_cache_size() == 10
    end
    withenv("SYNCOPADE_FUNCTION_CACHE_SIZE" => "2") do
        a, b, c = [(name, "M", "f") for name in ("a", "b", "c")]
        f, g = () -> 1, () -> 2
        @test cache_store_function!(a, f) === f
        @test cache_store_function!(a, g) === f
        @test cache_store_function!(b, g) === g
        @test cache_lookup_function(a) === f
        @test function_cache_lru == [a, b]
        @test cache_store_function!(c, g) === g
        @test cache_lookup_function(b) === nothing
        @test function_cache_lru == [c, a]
        @test clear_function_cache!() == 2
        @test isempty(function_cache)
        @test isempty(function_cache_lru)
    end
    for size in ("0", "-3")
        withenv("SYNCOPADE_FUNCTION_CACHE_SIZE" => size) do
            key = ("a", "M", "f")
            f = () -> 1
            @test configured_function_cache_size() == 0
            @test cache_store_function!(key, f) === f
            @test cache_lookup_function(key) === nothing
            @test clear_function_cache!() == 0
        end
    end
    mktempdir() do dir
        mount = mkdir(joinpath(dir, "mount"))
        fixture = joinpath(@__DIR__, "fixtures", "package_reload", "task_v1.jl")
        cp(fixture, joinpath(mount, "probe.jl"))
        cp(fixture, joinpath(dir, "probe.jl"))
        cd(dir) do
            @test resolve_source_script_path("probe", mount) == joinpath(mount, "probe.jl")
            @test resolve_source_script_path(joinpath(dir, "probe"), mount) == joinpath(dir, "probe.jl")
            @test resolve_source_script_path("missing/probe", mount) == joinpath(mount, "probe.jl")
            @test_throws ArgumentError resolve_source_script_path("", mount)
            @test_throws ArgumentError resolve_source_script_path("absent", mount)
            @test_throws ArgumentError resolve_source_script_path("probe", joinpath(dir, "absent"))
        end
        withenv("SYNCOPADE_MOUNT_ROOT_UNIX" => mount, "SYNCOPADE_MOUNT_ROOT_WINDOWS" => mount) do
            @test call_func("probe", "StandaloneTask", "run") == "V1"
            @test_throws MethodError call_func("probe", "StandaloneTask", "run", ["unexpected"])
            @test clear_function_cache!() == 1
        end
    end
end
