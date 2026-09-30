using Test

# Load definitions only: never start the conductor, probe a node, or send a task.
include(joinpath(@__DIR__, "..", "syncopadeConductor.jl"))

const EXPECTED_LEGACY_NODES = Dict(
    "lan12" => [
        (ip="192.168.12.2", port=8002, name="Chopper"),
        (ip="192.168.12.3", port=8003, name="ID-10"),
        (ip="192.168.12.4", port=8004, name="MSE-6"),
        (ip="192.168.12.5", port=8005, name="Crosshair"),
        (ip="192.168.12.6", port=8006, name="Wrecker"),
        (ip="192.168.12.7", port=8007, name="Echo"),
        (ip="192.168.12.8", port=8008, name="Hunter"),
        (ip="192.168.12.9", port=8009, name="Tech"),
        (ip="192.168.12.10", port=8010, name="Omega"),
        (ip="192.168.12.11", port=8011, name="GNK_EG-6"),
        (ip="192.168.12.12", port=8012, name="C-3PX"),
        (ip="192.168.12.13", port=8013, name="D-O"),
    ],
    "lan100" => [
        (ip="192.168.100.26", port=8026, name="C-3PX"),
        (ip="192.168.100.30", port=8030, name="Chopper"),
        (ip="192.168.100.37", port=8037, name="BD-1"),
        (ip="192.168.100.38", port=8038, name="GNK_EG-6"),
        (ip="192.168.100.48", port=8048, name="GONKY"),
        (ip="192.168.100.73", port=8073, name="Hunter"),
        (ip="192.168.100.74", port=8074, name="Tech"),
        (ip="192.168.100.75", port=8075, name="Crosshair"),
        (ip="192.168.100.76", port=8076, name="Wrecker"),
        (ip="192.168.100.77", port=8077, name="Echo"),
        (ip="192.168.100.78", port=8078, name="Omega"),
        (ip="192.168.100.95", port=8095, name="D-O"),
    ],
)

const EXPECTED_M4_NODES = Dict(
    "lan12" => [
        (ip="192.168.12.15", port=8015, name="KIX"),
        (ip="192.168.12.16", port=8016, name="FIVES"),
        (ip="192.168.12.17", port=8017, name="JESSE"),
        (ip="192.168.12.18", port=8018, name="REX"),
    ],
    "lan100" => [
        (ip="192.168.100.107", port=8107, name="KIX"),
        (ip="192.168.100.105", port=8105, name="FIVES"),
        (ip="192.168.100.106", port=8106, name="JESSE"),
        (ip="192.168.100.104", port=8104, name="REX"),
    ],
)

@testset "Node profiles and M4 priority without LAN access" begin
    original_profile = get(ENV, "SYNCOPADE_NODE_PROFILE", nothing)
    original_log = get(ENV, "SYNCOPADE_CONDUCTOR_LOG", nothing)
    @test Set(keys(SYNCOPADE_NODE_PROFILES)) == Set(["lan12", "lan100"])
    @test DEFAULT_SYNCOPADE_NODE_PROFILE == "lan12"
    withenv("SYNCOPADE_NODE_PROFILE" => nothing) do
        @test configured_node_profile() == "lan12"
        @test configured_node_entries() == configured_node_entries(; profile="lan12")
    end
    withenv("SYNCOPADE_NODE_PROFILE" => "unknown-profile") do
        @test_throws ArgumentError configured_node_entries()
        @test_throws ArgumentError geneAvailableNodeList()
        @test length(configured_node_entries(; profile="lan12")) == 16
    end

    artifact_dir = mktempdir() do dir
        withenv("SYNCOPADE_CONDUCTOR_LOG" => joinpath(dir, "events.csv")) do
            try
                for profile in ("lan12", "lan100")
                    @testset "$profile" begin
                        expected = vcat(EXPECTED_LEGACY_NODES[profile], EXPECTED_M4_NODES[profile])
                        entries = configured_node_entries(; profile)
                        @test length(entries) == 16
                        @test entries == expected
                        @test entries[1:12] == EXPECTED_LEGACY_NODES[profile]
                        @test entries[13:16] == EXPECTED_M4_NODES[profile]
                        @test length(unique([(e.ip, e.port) for e in entries])) == 16
                        @test length(unique([e.name for e in entries])) == 16
                        for entry in entries
                            @test parse(IPv4, entry.ip) isa IPv4
                            @test 1 <= entry.port <= 65535
                            @test entry.port == 8000 + parse(Int, split(entry.ip, '.')[end])
                        end

                        withenv("SYNCOPADE_NODE_PROFILE" => profile) do
                            @test configured_node_profile() == profile
                            @test configured_node_entries() == entries
                            nodes = geneAvailableNodeList()
                            @test length(nodes) == 16
                            @test [(ip=n.IP, port=n.port, name=n.name) for n in nodes] == expected
                            @test nodes !== geneAvailableNodeList()
                            @test isempty(node_states)
                            lock(node_states_lock) do
                                for node in nodes
                                    node_states[(node.IP, node.port)] = NodeRuntimeState(NODE_IDLE, UInt64(0), "", "")
                                end
                            end
                            selected_names = String[]
                            for (index, entry) in enumerate(reverse(expected))
                                task_id = "config-$profile-$index"
                                selected = reserve_idle_node_right_to_left!(nodes, task_id)
                                @test selected !== nothing
                                selected === nothing && break
                                @test (ip=selected.IP, port=selected.port, name=selected.name) == entry
                                @test get_node_runtime_state(selected).task_id == task_id
                                push!(selected_names, selected.name)
                            end
                            @test selected_names == vcat(["REX", "JESSE", "FIVES", "KIX"], reverse(getproperty.(EXPECTED_LEGACY_NODES[profile], :name)))
                            @test reserve_idle_node_right_to_left!(nodes, "no-idle-left") === nothing
                            @test isempty(task_queue)  # Reservations only; no task was submitted.
                            @test entries == expected  # Selection must not reorder the profile.
                            println("NODE_CONFIG profile=$profile nodes=$(length(nodes)) priority=$(join(selected_names[1:4], ",")) legacy_fallback=$(selected_names[5])")
                        end
                        lock(node_states_lock) do
                            empty!(node_states)
                        end
                    end
                end
            finally
                lock(node_states_lock) do
                    empty!(node_states)
                end
                stop_conductor_log_writer!()
            end
        end
        @test isfile(joinpath(dir, "events.csv"))
        return dir
    end
    @test !ispath(artifact_dir)
    @test isempty(node_states)
    @test conductor_log_task[] === nothing
    @test get(ENV, "SYNCOPADE_NODE_PROFILE", nothing) == original_profile
    @test get(ENV, "SYNCOPADE_CONDUCTOR_LOG", nothing) == original_log
end
