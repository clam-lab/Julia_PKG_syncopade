using Sockets

include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))

# CLI arguments:
#   ARGS[1]  = conductor_ip
#   ARGS[2]  = conductor_port
#   ARGS[3]  = callback_port
#   ARGS[4]  = num_tasks
#   ARGS[5]  = timeout_sec
#   ARGS[6]  = source
#   ARGS[7]  = module_name
#   ARGS[8]  = function_name
#   ARGS[9:] = function args... (each entry is passed as one String argument)
#
# Example:
#   julia test/conductor_submit_queuetests.jl \
#     192.168.100.96 9096 9160 10 120 \
#     /Volumes/syncopade_nfs/syncopadeBasicTestScript \
#     syncopadeBasicTestScript test "[2,3,5]" "[7,11,13]"

conductor_ip = length(ARGS) >= 1 ? ARGS[1] : "192.168.100.96"
conductor_port = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 9096
callback_port = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 9160
num_tasks = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 10
timeout_sec = length(ARGS) >= 5 ? parse(Float64, ARGS[5]) : 120.0

local_ip = string(getipaddr())
source = length(ARGS) >= 6 ? ARGS[6] : "/Volumes/syncopade_nfs/syncopadeBasicTestScript"
module_name = length(ARGS) >= 7 ? ARGS[7] : "syncopadeBasicTestScript"
function_name = length(ARGS) >= 8 ? ARGS[8] : "test"
fn_args = length(ARGS) >= 9 ? ARGS[9:end] : ["[2,3,5]", "[7,11,13]"]
expected = length(ARGS) >= 9 ? nothing : "30030.0"

println("conductor = ", conductor_ip, ":", conductor_port)
println("callback  = ", local_ip, ":", callback_port)
println("tasks     = ", num_tasks)
println("timeout   = ", timeout_sec, " sec")
println("target    = ", source, ":", module_name, ":", function_name)
println("args      = ", fn_args)
if expected !== nothing
    println("expected  = ", expected)
else
    println("expected  = (disabled: custom args)")
end

recv_done = Ref(false)
recv_count = Ref(0)
ok_count = Ref(0)
error_count = Ref(0)
bad_checksum_count = Ref(0)
bad_payload_count = Ref(0)
payloads = String[]
payload_lock = ReentrantLock()

@async begin
    bind_ip = getipaddr()
    server = listen(bind_ip, callback_port)
    println("queue result server bind address: ", bind_ip, ":", callback_port)
    try
        while recv_count[] < num_tasks
            sock = accept(server)
            try
                line = readline(sock)
                chk_ok, payload = verify_checksum(line)
                if !chk_ok
                    bad_checksum_count[] += 1
                    recv_count[] += 1
                    continue
                end

                parts = split(payload, '|')
                if length(parts) >= 4 && parts[1] == "RESULT"
                    status = parts[3]
                    if status == "OK"
                        value = join(parts[4:end], "|")
                        ok_count[] += 1
                        lock(payload_lock) do
                            push!(payloads, value)
                        end
                    elseif status == "ERROR" && length(parts) >= 5
                        error_count[] += 1
                        errType = parts[4]
                        errMsg = join(parts[5:end], "|")
                        lock(payload_lock) do
                            push!(payloads, errType * "|" * errMsg)
                        end
                    else
                        bad_payload_count[] += 1
                    end
                else
                    bad_payload_count[] += 1
                end
            finally
                close(sock)
                recv_count[] += 1
            end
        end
    finally
        recv_done[] = true
        close(server)
    end
end

task_ids = String[]
for i in 1:num_tasks
    task_id = submit_conductor_task(
        conductor_ip;
        conductor_port=conductor_port,
        coordinator_ip=local_ip,
        coordinator_port=callback_port,
        source=source,
        module_name=module_name,
        function_name=function_name,
        args=fn_args
    )
    push!(task_ids, task_id)
    println("submitted [", i, "/", num_tasks, "] task_id=", task_id)
end

w = Base.timedwait(() -> recv_done[], timeout_sec; pollint=0.05)
if w === :timed_out
    error(
        "timeout waiting callbacks: received=$(recv_count[]) ok=$(ok_count[]) error=$(error_count[]) " *
        "bad_checksum=$(bad_checksum_count[]) bad_payload=$(bad_payload_count[])"
    )
end

println("---- Queue Test Summary ----")
println("submitted      = ", length(task_ids))
println("received       = ", recv_count[])
println("ok             = ", ok_count[])
println("error          = ", error_count[])
println("bad_checksum   = ", bad_checksum_count[])
println("bad_payload    = ", bad_payload_count[])

if expected !== nothing
    mismatch = 0
    lock(payload_lock) do
        for p in payloads
            if p != expected
                mismatch += 1
            end
        end
    end
    println("expected match = ", ok_count[] - mismatch, "/", ok_count[])
    mismatch == 0 || error("payload mismatch count = " * string(mismatch))
end

if recv_count[] != num_tasks
    error("received count mismatch")
end

if error_count[] > 0 || bad_checksum_count[] > 0 || bad_payload_count[] > 0
    error("queue test failed with non-OK callbacks")
end

println("conductor queue submit test passed")
