using Test

include(joinpath(@__DIR__, "..", "syncopadeServer.jl"))

@testset "Server Admission State" begin
    try
        @test Threads.nthreads() >= 4
        @test get_server_state() == :idle

        @test try_reserve_server!()
        @test get_server_state() == :busy
        @test !try_reserve_server!()
        @test get_server_state() == :busy

        release_server!()
        @test get_server_state() == :idle
        @test try_reserve_server!()
        @test get_server_state() == :busy
        release_server!()

        tasks = [Threads.@spawn try_reserve_server!() for _ in 1:4]
        results = fetch.(tasks)
        @test count(identity, results) == 1
        @test count(==(false), results) == 3
        @test get_server_state() == :busy
    finally
        release_server!()
    end

    @test get_server_state() == :idle

    direct_job = SyncopadeJob(
        "127.0.0.1", 1, "source", "Module", "function", String[], "", "", 0
    )
    conductor_job = SyncopadeJob(
        "127.0.0.1", 1, "source", "Module", "function", String[],
        "task-1", "127.0.0.1", 9001
    )
    partial_job = SyncopadeJob(
        "127.0.0.1", 1, "source", "Module", "function", String[],
        "task-1", "", 0
    )
    @test !has_conductor_metadata(direct_job)
    @test has_conductor_metadata(conductor_job)
    @test !has_conductor_metadata(partial_job)
end
