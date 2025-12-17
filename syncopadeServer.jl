using Sockets

server = listen(8000)  # ポート8000で待つ

@async begin
    while true
        sock = accept(server)
        @async begin
            write(sock, "hello from Julia\n")
            close(sock)
        end
    end
end


function call_func(file_name::String, func_name::String)
    include(file_name * ".jl")

    mod = getfield(Main, Symbol(file_name))
    f = getfield(mod, Symbol(func_name))

    return f()
end

call_func("testScript4syncopade", "test_syncopade")