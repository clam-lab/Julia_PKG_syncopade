using Test
using Sockets

module ResultClientUnderTest
include(joinpath(@__DIR__, "..", "syncopadeClient.jl"))
end

module ResultServerUnderTest
include(joinpath(@__DIR__, "..", "syncopadeServer.jl"))
end

const RC = ResultClientUnderTest
const RS = ResultServerUnderTest

function result_test_job(
    callback_port::Int;
    task_id::String="",
    conductor_ip::String="",
    conductor_port::Int=0
)::RS.SyncopadeJob
    return RS.SyncopadeJob(
        "127.0.0.1",
        callback_port,
        "source",
        "Module",
        "function",
        String[],
        task_id,
        conductor_ip,
        conductor_port
    )
end

function capture_sent_result(job_builder::Function, send_builder::Function)
    listener = listen(IPv4("127.0.0.1"), 0)
    _, port_u = getsockname(listener)
    port = Int(port_u)
    receiver = @async begin
        socket = accept(listener)
        try
            readline(socket)
        finally
            close(socket)
            close(listener)
        end
    end
    job = job_builder(port)
    @test send_builder(job)
    line = fetch(receiver)
    checksum_ok, payload = RC.verify_checksum(line)
    @test checksum_ok
    return RC.parse_syncopade_result_payload(payload)
end

@testset "Syncopade Result Protocol" begin
    legacy_ok = RC.parse_syncopade_result_payload("RESULT|job-old|OK|value|tail")
    @test legacy_ok == RC.SyncopadeResultMessage(
        :legacy_result, "", "job-old", true, "value|tail"
    )

    legacy_error = RC.parse_syncopade_result_payload(
        "RESULT|job-old-error|ERROR|RUNTIME_ERROR|message|tail"
    )
    @test legacy_error == RC.SyncopadeResultMessage(
        :legacy_result,
        "",
        "job-old-error",
        false,
        "RUNTIME_ERROR|message|tail"
    )

    task_ok = RC.parse_syncopade_result_payload(
        "TASK_RESULT|task-new|job-new|OK|value|tail"
    )
    @test task_ok == RC.SyncopadeResultMessage(
        :task_result, "task-new", "job-new", true, "value|tail"
    )

    task_error = RC.parse_syncopade_result_payload(
        "TASK_RESULT|task-error|job-error|ERROR|METHOD_ERROR|message|tail"
    )
    @test task_error == RC.SyncopadeResultMessage(
        :task_result,
        "task-error",
        "job-error",
        false,
        "METHOD_ERROR|message|tail"
    )

    conductor_failure = RC.parse_syncopade_result_payload(
        "TASK_RESULT|task-no-worker||ERROR|QUEUE_TIMEOUT|deadline"
    )
    @test conductor_failure == RC.SyncopadeResultMessage(
        :task_result,
        "task-no-worker",
        "",
        false,
        "QUEUE_TIMEOUT|deadline"
    )

    for malformed in (
        "",
        "UNKNOWN|job|OK|value",
        "RESULT||OK|value",
        "RESULT|job|UNKNOWN|value",
        "RESULT|job|ERROR||message",
        "TASK_RESULT||job|OK|value",
        "TASK_RESULT|task||OK|value",
        "TASK_RESULT|task|job|UNKNOWN|value",
        "TASK_RESULT|task|job|ERROR||message",
        "TASK_RESULT|task|job|ERROR",
    )
        @test_throws ArgumentError RC.parse_syncopade_result_payload(malformed)
    end

    direct_job = result_test_job(1)
    complete_job = result_test_job(
        1;
        task_id="task-builder",
        conductor_ip="127.0.0.1",
        conductor_port=9001
    )
    partial_job = result_test_job(1; task_id="task-partial")
    parsed_conductor_job = RS.convMSG2JOB(
        "127.0.0.1|9101|source:Module:function|user-arg|" *
        "__syncopade_meta_task_id=task-parsed|" *
        "__syncopade_meta_conductor_ip=127.0.0.1|" *
        "__syncopade_meta_conductor_port=9001"
    )
    @test parsed_conductor_job.args == ["user-arg"]
    @test parsed_conductor_job.task_id == "task-parsed"
    @test parsed_conductor_job.conductor_ip_addr == "127.0.0.1"
    @test parsed_conductor_job.conductor_port == 9001
    @test RS.has_conductor_metadata(parsed_conductor_job)
    @test startswith(
        RS.build_result_payload(parsed_conductor_job, "job-parsed", true; result="value"),
        "TASK_RESULT|task-parsed|job-parsed|"
    )
    @test RS.build_result_payload(
        direct_job,
        "job-direct",
        true;
        result="direct-value"
    ) == "RESULT|job-direct|OK|direct-value"
    @test RS.build_result_payload(
        direct_job,
        "job-direct-error",
        false;
        errType="RUNTIME_ERROR",
        errMsg="direct-error"
    ) == "RESULT|job-direct-error|ERROR|RUNTIME_ERROR|direct-error"
    @test RS.build_result_payload(
        complete_job,
        "job-builder",
        true;
        result="task-value"
    ) == "TASK_RESULT|task-builder|job-builder|OK|task-value"
    @test RS.build_result_payload(
        complete_job,
        "job-builder-error",
        false;
        errType="ARG_ERROR",
        errMsg="task-error"
    ) == "TASK_RESULT|task-builder|job-builder-error|ERROR|ARG_ERROR|task-error"
    @test startswith(
        RS.build_result_payload(partial_job, "job-partial", true; result="value"),
        "RESULT|"
    )
    @test_throws ArgumentError RS.build_result_payload(direct_job, "", true)
    @test_throws ArgumentError RS.build_result_payload(direct_job, "job", false)

    calls3 = Any[]
    handler3 = (job_id, ok, payload) -> push!(calls3, (job_id, ok, payload))
    RC.invoke_syncopade_result_handler(handler3, task_ok)
    @test calls3 == [("job-new", true, "value|tail")]

    calls4 = Any[]
    handler4 = (task_id, job_id, ok, payload) ->
        push!(calls4, (task_id, job_id, ok, payload))
    RC.invoke_syncopade_result_handler(handler4, task_error)
    RC.invoke_syncopade_result_handler(handler4, legacy_ok)
    @test calls4 == [
        ("task-error", "job-error", false, "METHOD_ERROR|message|tail"),
        ("", "job-old", true, "value|tail"),
    ]

    sent_direct = capture_sent_result(
        port -> result_test_job(port),
        job -> RS.send_result(job, "job-loopback", true; result="direct-loopback")
    )
    @test sent_direct.protocol == :legacy_result
    @test isempty(sent_direct.task_id)
    @test sent_direct.job_id == "job-loopback"
    @test sent_direct.payload == "direct-loopback"

    sent_task = capture_sent_result(
        port -> result_test_job(
            port;
            task_id="task-loopback",
            conductor_ip="127.0.0.1",
            conductor_port=9001
        ),
        job -> RS.send_result(
            job,
            "job-task-loopback",
            false;
            errType="RUNTIME_ERROR",
            errMsg="task-loopback-error"
        )
    )
    @test sent_task.protocol == :task_result
    @test sent_task.task_id == "task-loopback"
    @test sent_task.job_id == "job-task-loopback"
    @test !sent_task.ok
    @test sent_task.payload == "RUNTIME_ERROR|task-loopback-error"
end

println("STEP9_RESULT=PASS_RESULT_PROTOCOL")
