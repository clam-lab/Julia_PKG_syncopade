include(joinpath(@__DIR__, "..", "..", "syncopadeServerSignals.jl"))
dir = only(ARGS)
signal = start_listener_interrupt()
GC.gc() # The native userdata pointer must remain rooted across collections.
@assert listener_interrupt_owner[] === signal
@assert !signal.requested[]
work = @async begin
    write(joinpath(dir, "ready"), "ready")
    while !isfile(joinpath(dir, "release"))
        sleep(0.01)
    end
    write(joinpath(dir, "work_done"), "done")
end
try
    while !signal.requested[]
        sleep(0.01)
    end
    write(joinpath(dir, "hook_entered"), "self_wait=$(current_task() === work)")
    wait(work)
    write(joinpath(dir, "hook_done"), "done")
finally
    close_listener_interrupt!(signal)
    close_listener_interrupt!(signal) # Repeated cleanup is safe.
    @assert listener_interrupt_owner[] === nothing
    @assert signal.closed[]
end
