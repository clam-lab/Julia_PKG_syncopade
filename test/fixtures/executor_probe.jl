module ExecutorProbe
echo(args...) = join(args, '|')
pid() = string(getpid())
environment(key) = join((Base.active_project(), pwd(), ENV[key], Threads.nthreads(:default), Threads.nthreads(:interactive)), '|')
fail() = throw(ArgumentError("deliberate fixture failure"))
function noisy()
    print(stdout, "x"^(256 * 1024))
    flush(stdout)
    return "noise-complete"
end
end
