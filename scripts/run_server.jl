#!/usr/bin/env julia

include(joinpath(@__DIR__, "..", "syncopadeServer.jl"))
if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
