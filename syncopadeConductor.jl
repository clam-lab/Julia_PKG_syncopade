struct NODES
    IP::String
    port::Int
end

# 利用可能な可能性のあるノードのリスト
nodes = NODES[] 
push!(nodes, NODES("192.168.100.26", 8026)) # C-3PX - Phyduck
push!(nodes, NODES("192.168.100.30", 8030)) # 

