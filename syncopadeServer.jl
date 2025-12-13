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


