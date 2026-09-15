module ListenerProbe
using ReloadProbe
const active = Ref(0)
const maximum_active = Ref(0)
function counted(trace, label)
    active[] += 1
    maximum_active[] = max(maximum_active[], active[])
    open(trace, "a") do io
        println(io, "START,$label,$(getpid()),$(active[])")
    end
    try
        sleep(0.03)
        return "$label,$(getpid()),$(maximum_active[])"
    finally
        active[] -= 1
        open(trace, "a") do io
            println(io, "END,$label,$(getpid()),$(active[])")
        end
    end
end
package_marker() = "$(ReloadProbe.marker()),$(getpid())"
fail() = throw(ArgumentError("listener fixture failure"))
function pause(ready_file, release_file)
    write(ready_file, string(getpid()))
    while !isfile(release_file)
        sleep(0.01)
    end
    return "released,$(getpid())"
end
end
