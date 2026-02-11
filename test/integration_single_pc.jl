using Sockets

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

# Prerequisites:
#   terminal A: julia syncopadeServer.jl
#   terminal B: julia syncopadeConductor.jl
# Then run:
#   julia test/integration_single_pc.jl

function last_octet(ip::String)::Int
    parts = split(ip, ".")
    return parse(Int, parts[end])
end

local_ip = string(getipaddr())
server_port = 8000 + last_octet(local_ip)
conductor_port = 9000 + last_octet(local_ip)
callback_port = 9103

println("local ip      = ", local_ip)
println("server port   = ", server_port)
println("conductor port= ", conductor_port)
println("callback port = ", callback_port)

println("checking server status...")
println(query_server_status(local_ip, server_port))

println("listing nodes from conductor...")
show_available_nodes(local_ip, conductor_port)

done = Ref(false)
function on_result(jobId::String, ok::Bool, payload::String)
    println("RESULT jobId=", jobId, " ok=", ok, " payload=", payload)
    done[] = true
end

syncopade_result_server_once(callback_port, on_result)

task_id = submit_conductor_task(
    local_ip;
    conductor_port=conductor_port,
    coordinator_ip=local_ip,
    coordinator_port=callback_port,
    source="testScript",
    module_name="testScript4syncopade",
    function_name="test_syncopade",
    args=["integration-single-pc"]
)

println("submitted conductor task_id = ", task_id)

t0 = time()
while !done[] && (time() - t0) < 40.0
    sleep(0.1)
end

if !done[]
    error("timeout waiting callback")
end

println("integration_single_pc passed")
