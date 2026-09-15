module PackageTask
using ReloadProbe
run() = join((ReloadProbe.marker(), getpid(), pathof(ReloadProbe)), '|')
end
