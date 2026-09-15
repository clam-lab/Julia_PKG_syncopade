module ListenerProbe
using ReloadProbe
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
