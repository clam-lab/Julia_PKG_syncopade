struct NODES
    IP::String
    port::Int
end

# 利用可能な可能性のあるノードのリストを返す関数
function  geneAvailableNodeList()
    nodes = NODES[] 
    push!(nodes, NODES("192.168.100.26", 8026)) # C-3PX - Phyduck
    push!(nodes, NODES("192.168.100.30", 8030)) # 
    
    return nodes        
end

