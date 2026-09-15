using Test
const RESTART_ALL_TEST_DIR = mktempdir()
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(RESTART_ALL_TEST_DIR, "events.csv")
include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))
include(joinpath(@__DIR__, "fixtures", "controlled_restart_listener.jl"))
using .ControlledRestartListener

node_for(listener, name) = NODES("127.0.0.1", listener.port, name)
function wait_restart_operation(id)
    @test timedwait(() -> istaskdone(conductor_restart_tasks[id]), 10; pollint=0.01) == :ok
    fetch(conductor_restart_tasks[id])
    return get_restart_operation(id)
end

function cleanup_restart_fixtures(listeners)
    for listener in listeners
        stop_restart_listener!(listener)
        @test isempty(listener.connections)
        @test isempty(listener.errors)
        rebound = listen(ip"127.0.0.1", listener.port)
        @test isopen(rebound)
        close(rebound)
    end
end

try
    @testset "Parallel restart sends before waiting and is idempotent" begin
        slow, fast = start_restart_listener(mode=:held), start_restart_listener()
        nodes = [node_for(slow, "slow"), node_for(fast, "fast"), node_for(fast, "duplicate")]
        id = string(uuid4())
        try
            @test start_conductor_restart!(id, nodes; query_timeout=1, restart_timeout=3).status == :accepted
            @test timedwait(() -> slow.restart_count == 1 && fast.restart_count == 1, 2; pollint=0.01) == :ok
            @test get_restart_operation(id).status == :running
            @test conductor_submissions_paused()
            @test start_conductor_restart!(id, NODES[]).status == :existing
            @test slow.restart_count == fast.restart_count == 1
            @test parse_management_fields(restart_operation_response(id))[4] == "running"
            @test start_conductor_restart!(string(uuid4()), nodes).status == :busy
            put!(slow.release, nothing)
            final = wait_restart_operation(id)
            @test final.summary == (total_nodes=2, success_nodes=2, failed_nodes=0, overall_success=true)
            @test length(final.results) == 2
            @test !conductor_submissions_paused()
            @test start_conductor_restart!(id, nodes).status == :existing
            @test slow.restart_count == fast.restart_count == 1
            fields = parse_management_fields(restart_operation_response(id))
            @test fields[1:8] == ["RESTART_ALL", "1", id, "complete", "2", "2", "0", "true"]
            @test length(fields) == 8 + 17 * 2
        finally
            put!(slow.release, nothing)
            cleanup_restart_fixtures([slow, fast])
        end
    end

    @testset "Mixed outcomes include every configured endpoint" begin
        modes = [:success, :busy, :unsupported, :id_mismatch, :startup_failed, :timeout, :drop]
        listeners = [start_restart_listener(; mode) for mode in modes]
        nodes = [node_for(listener, string(mode)) for (listener, mode) in zip(listeners, modes)]
        closed = listen(ip"127.0.0.1", 0)
        down_port = Int(getsockname(closed)[2])
        close(closed)
        push!(nodes, NODES("127.0.0.1", down_port, "down"))
        id = string(uuid4())
        try
            @test start_conductor_restart!(id, nodes; query_timeout=0.5, restart_timeout=0.25).status == :accepted
            final = wait_restart_operation(id)
            @test final.summary == (total_nodes=8, success_nodes=1, failed_nodes=7, overall_success=false)
            @test length(final.results) == 8
            expected = [:success, :busy, :unsupported, :id_mismatch, :startup_failed, :unknown, :unknown, :transport_error]
            @test [final.results[(node.IP, node.port)].status for node in nodes] == expected
            @test all(final.results[(nodes[index].IP, nodes[index].port)].request_sent for index in (6, 7))
            @test !final.results[(nodes[3].IP, nodes[3].port)].request_sent
            @test !final.results[(nodes[8].IP, nodes[8].port)].request_sent
            @test !conductor_submissions_paused()
            for listener in listeners
                @test timedwait(() -> isempty(listener.connections), 2; pollint=0.01) == :ok
            end
            unknown_node = nodes[6]
            unknown_listener = listeners[6]
            @test node_restart_quarantine(unknown_node) !== nothing
            generation = get_node_runtime_state(unknown_node).generation
            @test !apply_observed_node_state!(unknown_node, NODE_IDLE, generation)
            @test !reconcile_restart_quarantine!(unknown_node; timeout=1)
            @test !try_reserve_node!(unknown_node, "must-not-run")
            # Even a forced legacy observation cannot bypass quarantine on LIST/reservation.
            set_node_state!(unknown_node, NODE_IDLE)
            @test !("$(unknown_node.IP):$(unknown_node.port)" in idle_node_endpoints())
            @test reserve_idle_node_right_to_left!([unknown_node], "must-not-run") === nothing
            old_listener_id = unknown_listener.listener_id
            unknown_listener.listener_id = string(uuid4())
            finish_delayed_restart!(unknown_listener)
            @test !reconcile_restart_quarantine!(unknown_node; timeout=1)
            unknown_listener.listener_id = old_listener_id
            @test reconcile_restart_quarantine!(unknown_node; timeout=1)
            @test node_restart_quarantine(unknown_node) === nothing
            @test get_node_state(unknown_node) == NODE_IDLE
            @test try_reserve_node!(unknown_node, "after-reconciliation")
            @test release_node_assignment!(unknown_node, "after-reconciliation", "")
            @test reconcile_restart_quarantine!(nodes[7]; timeout=1)
            @test get_restart_operation(id).summary.failed_nodes == 7 # Final history is immutable.
            before = get_node_runtime_state(nodes[1])
            @test !record_restart_node_result!(id, nodes[1], final.results[(nodes[1].IP, nodes[1].port)])
            @test get_node_runtime_state(nodes[1]) == before
            @test length(parse_management_fields(restart_operation_response(id))) == 8 + 17 * 8
        finally
            cleanup_restart_fixtures(listeners)
        end
    end

    @testset "No target and unknown operation are not success" begin
        id = string(uuid4())
        @test start_conductor_restart!(id, NODES[]).status == :accepted
        result = wait_restart_operation(id)
        @test result.summary == (total_nodes=0, success_nodes=0, failed_nodes=0, overall_success=false)
        unknown = string(uuid4())
        @test parse_management_fields(restart_operation_response(unknown)) == ["RESTART_ALL", "1", unknown, "unknown"]
        @test parse_management_fields(restart_operation_response(unknown; busy=true))[4] == "busy"
    end
finally
    stop_conductor_log_writer!()
end
