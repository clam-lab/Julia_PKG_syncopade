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
       SyncopadeResultMessage,
       parse_syncopade_result_payload,
       query_server_status,
       query_conductor_nodes,
       ConductorTaskStatus,
       KnownConductorTaskStatus,
       UnknownConductorTaskStatus,
       parse_conductor_task_status_response,
       query_conductor_task_status,
       parse_conductor_nodes,
       show_available_nodes,
       clear_conductor_node_caches,
       submit_conductor_task,
       submit_conductor_task_and_wait

end
