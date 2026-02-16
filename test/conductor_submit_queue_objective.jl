using Sockets
using Random

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
#   julia test/conductor_submit_queue_objective.jl \
#     192.168.100.96 9096 9170 10 180 \
#     /Volumes/syncopade_nfs/Julia_GeneralObjectiveFunction \
#     Julia_GeneralObjectiveFunction objective_from_string "[0.1,0.2,0.3]"

conductor_ip = length(ARGS) >= 1 ? ARGS[1] : "192.168.100.96"
conductor_port = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 9096
callback_port = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 9170
num_tasks = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 30
timeout_sec = length(ARGS) >= 5 ? parse(Float64, ARGS[5]) : 180.0

local_ip = string(getipaddr())
source = length(ARGS) >= 6 ? ARGS[6] : "/Volumes/syncopade_nfs/Julia_GeneralObjectiveFunction"
module_name = length(ARGS) >= 7 ? ARGS[7] : "Julia_GeneralObjectiveFunction"
function_name = length(ARGS) >= 8 ? ARGS[8] : "objective_from_string"
fn_args = length(ARGS) >= 9 ? ARGS[9:end] : ["[0.1,0.2,0.3]"]
random_x_mode = get(ENV, "SYNCOPADE_RANDOM_X", "0") == "1"
random_x_dim = parse(Int, get(ENV, "SYNCOPADE_RANDOM_X_DIM", "3"))
random_x_seed_str = get(ENV, "SYNCOPADE_RANDOM_X_SEED", "")
if !isempty(random_x_seed_str)
    Random.seed!(parse(Int, random_x_seed_str))
end

println("conductor = ", conductor_ip, ":", conductor_port)
println("callback  = ", local_ip, ":", callback_port)
println("tasks     = ", num_tasks)
println("timeout   = ", timeout_sec, " sec")
println("target    = ", source, ":", module_name, ":", function_name)
println("args      = ", fn_args)
println("random_x  = ", random_x_mode ? "on (dim=$(random_x_dim))" : "off")

recv_done = Ref(false)
recv_count = Ref(0)
ok_count = Ref(0)
error_count = Ref(0)
bad_checksum_count = Ref(0)
bad_payload_count = Ref(0)
bad_value_count = Ref(0)
values = Float64[]
values_lock = ReentrantLock()

@async begin
    bind_ip = getipaddr()
    server = listen(bind_ip, callback_port)
    println("objective queue result server bind address: ", bind_ip, ":", callback_port)
    try
        while recv_count[] < num_tasks
            sock = accept(server)
            try
                line = readline(sock)
                chk_ok, payload = verify_checksum(line)
                if !chk_ok
                    bad_checksum_count[] += 1
                    continue
                end

                parts = split(payload, '|')
                if length(parts) >= 4 && parts[1] == "RESULT"
                    status = parts[3]
                    if status == "OK"
                        value_str = join(parts[4:end], "|")
                        value = try
                            parse(Float64, value_str)
                        catch
                            bad_value_count[] += 1
                            NaN
                        end
                        if isfinite(value)
                            ok_count[] += 1
                            lock(values_lock) do
                                push!(values, value)
                            end
                        else
                            bad_value_count[] += 1
                        end
                    elseif status == "ERROR" && length(parts) >= 5
                        error_count[] += 1
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
    task_args = fn_args
    if random_x_mode
        x = randn(random_x_dim)
        x_arg = "[" * join(string.(x), ",") * "]"
        task_args = [x_arg]
        println("x[", i, "] = ", x_arg)
    end

    task_id = submit_conductor_task(
        conductor_ip;
        conductor_port=conductor_port,
        coordinator_ip=local_ip,
        coordinator_port=callback_port,
        source=source,
        module_name=module_name,
        function_name=function_name,
        args=task_args
    )
    push!(task_ids, task_id)
    println("submitted [", i, "/", num_tasks, "] task_id=", task_id)
end

w = Base.timedwait(() -> recv_done[], timeout_sec; pollint=0.05)
if w === :timed_out
    error(
        "timeout waiting callbacks: received=$(recv_count[]) ok=$(ok_count[]) error=$(error_count[]) " *
        "bad_checksum=$(bad_checksum_count[]) bad_payload=$(bad_payload_count[]) bad_value=$(bad_value_count[])"
    )
end

stats = lock(values_lock) do
    if isempty(values)
        nothing
    else
        (minimum(values), maximum(values), sum(values) / length(values))
    end
end
vmin = stats === nothing ? NaN : stats[1]
vmax = stats === nothing ? NaN : stats[2]
vavg = stats === nothing ? NaN : stats[3]

println("---- Objective Queue Summary ----")
println("submitted      = ", length(task_ids))
println("received       = ", recv_count[])
println("ok             = ", ok_count[])
println("error          = ", error_count[])
println("bad_checksum   = ", bad_checksum_count[])
println("bad_payload    = ", bad_payload_count[])
println("bad_value      = ", bad_value_count[])
println("min(value)     = ", vmin)
println("max(value)     = ", vmax)
println("avg(value)     = ", vavg)

if recv_count[] != num_tasks
    error("received count mismatch")
end

if error_count[] > 0 || bad_checksum_count[] > 0 || bad_payload_count[] > 0 || bad_value_count[] > 0
    error("objective queue test failed")
end

println("conductor objective queue test passed")
