using Sockets

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

function last_octet(ip::String)::Int
    parts = split(ip, ".")
    return parse(Int, parts[end])
end

conductor_ip = length(ARGS) >= 1 ? ARGS[1] : "192.168.100.96"
conductor_port = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 9096
callback_port = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 9150
timeout_sec = length(ARGS) >= 4 ? parse(Float64, ARGS[4]) : 600.0

local_ip = string(getipaddr())

println("conductor = ", conductor_ip, ":", conductor_port)
println("callback  = ", local_ip, ":", callback_port)
println("timeout   = ", timeout_sec, " sec")
println("expected result = 30030")

done = Ref(false)
ok_ref = Ref(false)
payload_ref = Ref("")

function on_result(jobId::String, ok::Bool, payload::String)
    println("RESULT jobId=", jobId, " ok=", ok)
    println(payload)
    ok_ref[] = ok
    payload_ref[] = payload
    done[] = true
end

syncopade_result_server_once(callback_port, on_result)

task_id = submit_conductor_task(
    conductor_ip;
    conductor_port=conductor_port,
    coordinator_ip=local_ip,
    coordinator_port=callback_port,
    source="/Volumes/syncopade_nfs/syncopadeBasicTestScript",
    module_name="syncopadeBasicTestScript",
    function_name="test",
    args=["[2,3,5]", "[7,11,13]"]
)

println("submitted conductor task_id = ", task_id)

t0 = time()
while !done[] && (time() - t0) < timeout_sec
    sleep(0.1)
end

if !done[]
    error("timeout waiting callback")
end

if !ok_ref[]
    error("worker returned error: " * payload_ref[])
end

println("conductor submit test passed")
