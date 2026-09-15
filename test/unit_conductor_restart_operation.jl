using Test
const RESTART_OPERATION_TEST_DIR = mktempdir()
ENV["SYNCOPADE_CONDUCTOR_LOG"] = joinpath(RESTART_OPERATION_TEST_DIR, "events.csv")
include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))

function reset_restart_test_state!()
    @assert conductor_mutation_owner[] === nothing
    empty!(task_queue)
    empty!(task_runtime_states)
    empty!(task_acceptance_windows)
    empty!(conductor_task_records)
    empty!(task_terminal_notifications)
    empty!(node_states)
end

test_restart_task() = ConductorTask(string(uuid4()), "127.0.0.1", 1, "source", "Module", "run", String[], 0)
function failure_results(targets)
    return Dict((node.IP, node.port) => ServerRestartResult(:busy, "", "", nothing, "fixture refusal", true) for node in targets)
end

try
    @testset "Conductor restart operation admission and identity" begin
        nodes = [NODES("127.0.0.1", 10001, "A"), NODES("127.0.0.1", 10001, "duplicate"), NODES("127.0.0.1", 10002, "B")]
        reset_restart_test_state!()
        id = string(uuid4())
        @test_throws ArgumentError begin_restart_operation!("", nodes)
        @test get_restart_operation(id) === nothing
        started = begin_restart_operation!(id, nodes)
        @test started.status == :accepted
        @test length(started.operation.targets) == 2
        @test started.operation.targets[1].name == "A"
        @test started.operation.summary === nothing
        @test conductor_submissions_paused()
        @test begin_restart_operation!(id, NODES[]).status == :existing
        @test begin_restart_operation!(string(uuid4()), nodes).status == :busy
        @test_throws ConductorMaintenanceBusyError enqueue_task!(test_restart_task())
        @test queue_len() == 0
        @test isempty(task_runtime_states)
        set_node_state!(nodes[1], NODE_IDLE)
        @test !try_reserve_node!(nodes[1], "job")
        @test reserve_idle_node_right_to_left!(nodes, "job") === nothing
        run_dispatch_cycle!(nodes)
        @test get_node_state(nodes[1]) == NODE_IDLE
        @test begin_cache_clear_operation!() === nothing
        @test_throws ConductorMaintenanceBusyError clear_all_node_caches(nodes)
        @test_throws ArgumentError finish_restart_operation!(id, Dict())
        @test conductor_submissions_paused()
        @test !finish_restart_operation!(string(uuid4()), failure_results(started.operation.targets))
        @test finish_restart_operation!(id, failure_results(started.operation.targets))
        completed = get_restart_operation(id)
        @test completed.summary == (total_nodes=2, success_nodes=0, failed_nodes=2, overall_success=false)
        @test !conductor_submissions_paused()
        @test begin_restart_operation!(id, NODES[]).operation.status == :complete
        @test !finish_restart_operation!(id, failure_results(started.operation.targets))
        empty!(completed.targets)
        empty!(completed.results)
        @test length(get_restart_operation(id).targets) == 2
        @test length(get_restart_operation(id).results) == 2
        reset_restart_test_state!()
        empty_id = string(uuid4())
        @test begin_restart_operation!(empty_id, NODES[]).status == :accepted
        @test finish_restart_operation!(empty_id, Dict())
        @test !get_restart_operation(empty_id).summary.overall_success
    end

    @testset "Queued reserved running unknown all block operation" begin
        node = NODES("127.0.0.1", 10001, "local")
        for state in (TASK_QUEUED, TASK_RESERVED, TASK_RUNNING, TASK_DISPATCH_UNKNOWN)
            reset_restart_test_state!()
            task = test_restart_task()
            enqueue_task!(task)
            if state != TASK_QUEUED
                pop_task!()
                @test mark_task_reserved!(task.task_id)
                state == TASK_RUNNING && @test mark_task_running!(task.task_id, "job")
                state == TASK_DISPATCH_UNKNOWN && @test mark_task_dispatch_unknown!(task.task_id)
            end
            @test begin_restart_operation!(string(uuid4()), [node]).status == :busy
            @test conductor_mutation_owner[] === nothing
        end
        reset_restart_test_state!()
        set_node_state!(node, NODE_IDLE)
        @test try_reserve_node!(node, "direct-reservation")
        @test begin_restart_operation!(string(uuid4()), [node]).status == :busy
        reset_restart_test_state!()
        owner = begin_cache_clear_operation!()
        @test owner !== nothing
        @test begin_restart_operation!(string(uuid4()), [node]).status == :busy
        @test !finish_conductor_mutation!((:cache_clear, "wrong"))
        @test finish_conductor_mutation!(owner)
        @test_throws ErrorException with_conductor_cache_operation(() -> error("controlled operation error"))
        @test conductor_mutation_owner[] === nothing
    end

    @testset "Concurrent submission versus restart is exclusive" begin
        for _ in 1:24
            reset_restart_test_state!()
            id = string(uuid4())
            task = test_restart_task()
            submit = Threads.@spawn try
                enqueue_task!(task)
                true
            catch error
                error isa ConductorMaintenanceBusyError || rethrow()
                false
            end
            restart = Threads.@spawn begin_restart_operation!(id, NODES[])
            accepted_submit = fetch(submit)
            accepted_restart = fetch(restart).status == :accepted
            @test xor(accepted_submit, accepted_restart)
            if accepted_restart
                @test queue_len() == 0
                @test finish_restart_operation!(id, Dict())
            else
                @test queue_len() == 1
            end
        end
        reset_restart_test_state!()
    end
finally
    stop_conductor_log_writer!()
end
