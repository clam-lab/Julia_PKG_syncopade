module ExecutorProbe
echo(args...) = join(args, '|')
pid() = string(getpid())
fail() = throw(ArgumentError("deliberate fixture failure"))
function noisy()
    print(stdout, "x"^(256 * 1024))
    flush(stdout)
    return "noise-complete"
end
end
