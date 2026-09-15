# Fixture-only deployment selection; no dependency is added to the repository Project.
pushfirst!(LOAD_PATH, @__DIR__)
module PackageTask
using ReloadProbe
run() = join((ReloadProbe.marker(), getpid(), pathof(ReloadProbe)), '|')
end
