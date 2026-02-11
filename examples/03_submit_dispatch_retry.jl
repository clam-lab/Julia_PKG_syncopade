using Sockets

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

function last_octet(ip::String)::Int
    parts = split(ip, ".")
    return parse(Int, parts[end])
end

local_ip = string(getipaddr())
conductor_ip = length(ARGS) >= 1 ? ARGS[1] : local_ip
conductor_port = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : (9000 + last_octet(conductor_ip))
callback_port = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 9102

println("conductor = ", conductor_ip, ":", conductor_port)
println("callback  = ", local_ip, ":", callback_port)

done = Ref(false)
function on_result(jobId::String, ok::Bool, payload::String)
    println("RESULT jobId=", jobId, " ok=", ok, " payload=", payload)
    done[] = true
end

syncopade_result_server_once(callback_port, on_result)

task_id = submit_conductor_task(
    conductor_ip;
    conductor_port=conductor_port,
    coordinator_ip=local_ip,
    coordinator_port=callback_port,
    source="testScript",
    module_name="testScript4syncopade",
    function_name="test_syncopade",
    args=["example-03"]
)

println("queued task_id = ", task_id)

t0 = time()
while !done[] && (time() - t0) < 30.0
    sleep(0.1)
end

if !done[]
    error("timeout waiting callback. worker unavailable or still retrying")
end
