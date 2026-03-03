const SYNCOPADE_NODE_PROFILES = Dict(
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

const DEFAULT_SYNCOPADE_NODE_PROFILE = "lan12"

function configured_node_profile()::String
    return get(ENV, "SYNCOPADE_NODE_PROFILE", DEFAULT_SYNCOPADE_NODE_PROFILE)
end

function configured_node_entries(; profile::AbstractString=configured_node_profile())
    key = String(profile)
    entries = get(SYNCOPADE_NODE_PROFILES, key, nothing)
    if entries === nothing
        available = join(sort!(collect(keys(SYNCOPADE_NODE_PROFILES))), ", ")
        throw(ArgumentError("Unknown SYNCOPADE_NODE_PROFILE=$(key). Available profiles: $(available)"))
    end
    return entries
end
