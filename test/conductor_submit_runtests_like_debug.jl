using Sockets

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

# CLI arguments:
#   ARGS[1]  = conductor_ip
#   ARGS[2]  = conductor_port
#   ARGS[3]  = callback_port
#   ARGS[4]  = timeout_sec
#   ARGS[5]  = source
#   ARGS[6]  = module_name
#   ARGS[7]  = function_name
#   ARGS[8:] = function args... (each entry is passed as one String argument)
conductor_ip = length(ARGS) >= 1 ? ARGS[1] : "192.168.100.96"
conductor_port = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 9096
callback_port = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 9150
timeout_sec = length(ARGS) >= 4 ? parse(Float64, ARGS[4]) : 60.0

local_ip = string(getipaddr())
source = length(ARGS) >= 5 ? ARGS[5] : "/Volumes/syncopade_nfs/syncopadeBasicTestScript"
module_name = length(ARGS) >= 6 ? ARGS[6] : "syncopadeBasicTestScript"
function_name = length(ARGS) >= 7 ? ARGS[7] : "test"
args = length(ARGS) >= 8 ? ARGS[8:end] : ["[2,3,5]", "[7,11,13]"]

println("conductor = ", conductor_ip, ":", conductor_port)
println("callback  = ", local_ip, ":", callback_port)
println("timeout   = ", timeout_sec, " sec")
println("target    = ", source, ":", module_name, ":", function_name)
println("args      = ", args)

done = Ref(false)

@async begin
    server = listen(getipaddr(), callback_port)
    println("debug result server bind address: ", string(getipaddr()), ":", callback_port)
    sock = accept(server)
    try
        line = readline(sock)
        println("raw callback line = ", line)
        chk_ok, payload = verify_checksum(line)
        println("callback checksum ok = ", chk_ok)
        if chk_ok
            println("callback payload = ", payload)
        end
    finally
        done[] = true
        close(sock)
        close(server)
    end
end

task_id = submit_conductor_task(
    conductor_ip;
    conductor_port=conductor_port,
    coordinator_ip=local_ip,
    coordinator_port=callback_port,
    source=source,
    module_name=module_name,
    function_name=function_name,
    args=args
)

println("submitted conductor task_id = ", task_id)

t0 = time()
while !done[] && (time() - t0) < timeout_sec
    sleep(0.1)
end

if !done[]
    error("timeout waiting callback")
end
