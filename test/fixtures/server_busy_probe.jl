module SyncopadeServerBusyProbe

const active_lock = ReentrantLock()
const active_jobs = Ref(0)
const max_active_jobs = Ref(0)

"""
    busy_probe(label::String, sleep_seconds::String) -> String

Hold one server job active for `sleep_seconds` and return concurrency evidence.
The module-level counters are shared by jobs loaded from the same server process.
"""
function busy_probe(label::String, sleep_seconds::String)::String
    (occursin(',', label) || occursin('=', label)) &&
        throw(ArgumentError("label must not contain ',' or '=': $label"))

    seconds = try
        parse(Float64, strip(sleep_seconds))
    catch
        throw(ArgumentError("invalid sleep_seconds: $sleep_seconds"))
    end
    (isfinite(seconds) && seconds > 0) ||
        throw(ArgumentError("sleep_seconds must be finite and > 0: $sleep_seconds"))

    active_at_entry = 0
    started_ns = UInt64(0)
    lock(active_lock) do
        active_jobs[] += 1
        active_at_entry = active_jobs[]
        max_active_jobs[] = max(max_active_jobs[], active_jobs[])
        started_ns = time_ns()
    end

    try
        sleep(seconds)
        finished_ns = time_ns()
        max_active = lock(active_lock) do
            max_active_jobs[]
        end
        return join(
            String[
                "label=$(label)",
                "active_at_entry=$(active_at_entry)",
                "max_active=$(max_active)",
                "started_ns=$(started_ns)",
                "finished_ns=$(finished_ns)",
            ],
            ",",
        )
    finally
        lock(active_lock) do
            active_jobs[] -= 1
            active_jobs[] >= 0 || error("active job counter became negative")
        end
    end
end

end
