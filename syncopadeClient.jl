using Sockets

sock = connect("127.0.0.1", 8000)
println(readline(sock))
close(sock)
