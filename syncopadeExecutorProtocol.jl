module ExecutorProtocol
using UUIDs

export ExecutorMessage, write_executor_message, read_executor_message, expect_executor_message
const EXECUTOR_PROTOCOL_VERSION = "1"
const MAX_FRAME_BYTES = 16 * 1024 * 1024
const MAX_FIELDS = 4096

struct ExecutorMessage
    kind::String
    listener_id::String
    server_id::String
    request_id::String
    data::Vector{String}
end

function valid_uuid(value::String)
    try
        return string(UUID(value)) == value
    catch
        return false
    end
end

function validate_message(message::ExecutorMessage)
    valid_uuid(message.listener_id) && valid_uuid(message.server_id) || throw(ArgumentError("invalid runtime ID"))
    data = message.data
    if message.kind == "READY"
        isempty(message.request_id) || throw(ArgumentError("READY must not have a request ID"))
        length(data) == 3 || throw(ArgumentError("invalid READY fields"))
        pid = tryparse(Int, data[1])
        pid !== nothing && pid > 0 && !isempty(data[2]) && !isempty(data[3]) || throw(ArgumentError("invalid READY data"))
    else
        valid_uuid(message.request_id) || throw(ArgumentError("invalid request ID"))
        if message.kind == "EXECUTE"
            length(data) >= 3 && all(!isempty, data[1:3]) || throw(ArgumentError("invalid EXECUTE fields"))
        elseif message.kind == "RESULT"
            (!isempty(data) && ((data[1] == "OK" && length(data) == 2) ||
              (data[1] == "ERROR" && length(data) == 3 && !isempty(data[2])))) || throw(ArgumentError("invalid RESULT fields"))
        elseif message.kind == "CLEARED"
            length(data) == 1 || throw(ArgumentError("invalid CLEARED fields"))
            count = tryparse(Int, data[1])
            count !== nothing && count >= 0 || throw(ArgumentError("invalid CLEARED count"))
        elseif message.kind in ("CLEAR", "STOP", "STOPPED")
            isempty(data) || throw(ArgumentError("unexpected control fields"))
        else
            throw(ArgumentError("unknown executor message kind"))
        end
    end
    return message
end

function write_u32(io::IO, value::Integer)
    0 <= value <= typemax(UInt32) || throw(ArgumentError("length outside UInt32"))
    word = UInt32(value)
    for shift in (24, 16, 8, 0)
        write(io, UInt8((word >> shift) & 0xff))
    end
end

function read_exact(io::IO, count::Int)
    bytes = read(io, count)
    length(bytes) == count || throw(EOFError())
    return bytes
end

function read_u32(io::IO)
    bytes = read_exact(io, 4)
    return Int((UInt32(bytes[1]) << 24) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 8) | UInt32(bytes[4]))
end

function write_executor_message(io::IO, message::ExecutorMessage)
    validate_message(message)
    fields = vcat([EXECUTOR_PROTOCOL_VERSION, message.kind, message.listener_id, message.server_id, message.request_id], message.data)
    length(fields) <= MAX_FIELDS || throw(ArgumentError("too many fields"))
    total = 4 + sum(field -> 4 + ncodeunits(field), fields)
    total <= MAX_FRAME_BYTES || throw(ArgumentError("executor frame too large"))
    all(isvalid, fields) || throw(ArgumentError("invalid UTF-8"))
    buffer = IOBuffer()
    write_u32(buffer, total)
    write_u32(buffer, length(fields))
    for field in fields
        write_u32(buffer, ncodeunits(field))
        write(buffer, field)
    end
    write(io, take!(buffer))
    flush(io)
    return nothing
end

function read_executor_message(io::IO)
    length_bytes = read_u32(io)
    4 <= length_bytes <= MAX_FRAME_BYTES || throw(ArgumentError("invalid executor frame length"))
    buffer = IOBuffer(read_exact(io, length_bytes))
    count = read_u32(buffer)
    5 <= count <= MAX_FIELDS || throw(ArgumentError("invalid field count"))
    fields = String[]
    for _ in 1:count
        size = read_u32(buffer)
        size <= bytesavailable(buffer) || throw(ArgumentError("field exceeds frame"))
        value = String(read_exact(buffer, size))
        isvalid(value) || throw(ArgumentError("invalid UTF-8"))
        push!(fields, value)
    end
    eof(buffer) || throw(ArgumentError("trailing frame bytes"))
    fields[1] == EXECUTOR_PROTOCOL_VERSION || throw(ArgumentError("unsupported executor protocol"))
    return validate_message(ExecutorMessage(fields[2], fields[3], fields[4], fields[5], fields[6:end]))
end

function expect_executor_message(message::ExecutorMessage, kind::String, listener_id::String, server_id::String, request_id::String)
    validate_message(message)
    message.kind == kind && message.listener_id == listener_id && message.server_id == server_id &&
        message.request_id == request_id || throw(ArgumentError("executor response identity or kind mismatch"))
    return message
end
end
