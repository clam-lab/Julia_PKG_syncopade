include(joinpath(@__DIR__, "..", "syncopadeExecutor.jl"))

if abspath(PROGRAM_FILE) == @__FILE__
    executor_main()
end
