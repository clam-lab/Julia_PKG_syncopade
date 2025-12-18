module testScript4syncopade

    function test_syncopade(arg::String)
        println("Running syncopade tests...")
        println("Received arg = ", arg)

        sleep(3)  # Simulate a time-consuming task
        
        return "ARG=" * arg
    end

end

