module testScript4syncopade

    const OBJECTIVE_FILE = "/Volumes/syncopade_nfs/Julia_GeneralObjectiveFunction.jl"
    const _objective_loaded = Ref(false)

    function _ensure_objective_loaded!()
        if !_objective_loaded[]
            include(OBJECTIVE_FILE)
            _objective_loaded[] = true
        end
        return nothing
    end

    # Accepts formats like:
    # - "0.1,0.2,0.3"
    # - "[0.1, 0.2, 0.3]"
    function _parse_vector_arg(x_str::String)::Vector{Float64}
        s = strip(x_str)
        if startswith(s, "[") && endswith(s, "]")
            s = strip(s[2:end-1])
        end
        isempty(s) && throw(ArgumentError("x is empty"))

        parts = split(s, ',')
        x = Float64[]
        for p in parts
            v = strip(p)
            isempty(v) && continue
            push!(x, parse(Float64, v))
        end
        isempty(x) && throw(ArgumentError("failed to parse x from: $x_str"))
        return x
    end

    function objective_from_string(x_str::String)
        _ensure_objective_loaded!()
        x = _parse_vector_arg(x_str)
        mod = Base.invokelatest(getfield, @__MODULE__, :Julia_GeneralObjectiveFunction)
        f = Base.invokelatest(getfield, mod, :objective)
        return Base.invokelatest(f, x)
    end

    # Basic success-path test: returns the same payload with prefix.
    function test_echo(arg::String)
        return "ECHO=" * arg
    end

    # Delay-path test: argument is seconds (string), sleeps then returns.
    function test_sleep(sec_str::String)
        sec = parse(Float64, strip(sec_str))
        sec < 0 && throw(ArgumentError("sec must be >= 0"))
        sleep(sec)
        return "SLEPT=" * string(sec)
    end

    # Failure-path test: intentionally raises an error for callback ERROR flow.
    function test_raise(msg::String)
        error("INTENTIONAL_TEST_ERROR: " * msg)
    end

    # Objective wrapper test with optional exec mode hint (for future extension).
    # mode is currently informational and ignored by the objective call.
    function objective_test(mode::String, x_str::String)
        _ = mode
        return objective_from_string(x_str)
    end

    function test_syncopade(arg::String)
        println("Running syncopade tests...")
        println("Received arg = ", arg)

        sleep(3)  # Simulate a time-consuming task
        
        return "ARG=" * arg
    end

    function main()
        test_syncopade()
    end

    main()

end
