using Sockets

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

function last_octet(ip::String)::Int
    parts = split(ip, ".")
    return parse(Int, parts[end])
end

local_ip = string(getipaddr())
server_ip = length(ARGS) >= 1 ? ARGS[1] : local_ip
server_port = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : (8000 + last_octet(server_ip))
callback_port = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 9101

println("target server = ", server_ip, ":", server_port)
println("callback bind = ", local_ip, ":", callback_port)

status = query_server_status(server_ip, server_port)
println("server status = ", status)

if status != "STATUS|idle"
    error("server is not idle")
end

done = Ref(false)
function on_result(jobId::String, ok::Bool, payload::String)
    println("RESULT jobId=", jobId, " ok=", ok, " payload=", payload)
    done[] = true
end

syncopade_result_server_once(callback_port, on_result)

client = SyncopadeClient(
    server_ip,
    server_port,
    local_ip,
    callback_port,
    "testScript",
    "testScript4syncopade",
    "test_syncopade",
    ["example-01"]
)

jobId = syncopade_calc_request(client)
println("submitted jobId = ", jobId)

t0 = time()
while !done[] && (time() - t0) < 20.0
    sleep(0.1)
end

if !done[]
    error("timeout waiting callback")
end
