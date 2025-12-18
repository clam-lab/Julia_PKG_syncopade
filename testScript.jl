module testScript4syncopade

    function test_syncopade(arg::String)
        println("Running syncopade tests...")
        println("Received arg = ", arg)
        return "ARG=" * arg
    end

end