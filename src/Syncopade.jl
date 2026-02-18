module Syncopade

include("../syncopadeClient.jl")

export SyncopadeClient,
       geneXORchecksum,
       checksum_hex,
       add_checksum,
       verify_checksum,
       syncopade_calc_request,
       syncopade_result_server,
       syncopade_result_server_once,
       query_server_status,
       query_conductor_nodes,
       parse_conductor_nodes,
       show_available_nodes,
       submit_conductor_task,
       submit_conductor_task_and_wait

end
