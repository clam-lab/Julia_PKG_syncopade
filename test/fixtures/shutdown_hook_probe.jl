# Preflight for atexit-based draining; the controlling test owns this directory.
dir = only(ARGS)
Base.exit_on_sigint(true)
work = @async begin
    write(joinpath(dir, "ready"), "ready")
    while !isfile(joinpath(dir, "release"))
        sleep(0.01)
    end
    write(joinpath(dir, "work_done"), "done")
end
atexit() do
    write(joinpath(dir, "hook_entered"), "self_wait=$(current_task() === work)")
    current_task() === work && error("exit hook cannot wait for its own interrupted task")
    wait(work)
    write(joinpath(dir, "hook_done"), "done")
end
wait(Condition())
