# CLI-only cooperative SIGINT handling. Merely including this file installs no
# handler. libuv invokes these callbacks on the Julia event loop, not in an OS
# signal handler. Its handler prevents Julia's asynchronous InterruptException
# from unwinding an arbitrary listener task.
mutable struct ListenerInterrupt
    handle::Ptr{Cvoid}
    requested::Threads.Atomic{Bool}
    closed::Threads.Atomic{Bool}
end

# Keep the Julia object alive while its pointer is stored in the native handle.
# Only one CLI main owns SIGINT in a process. Library listener APIs do not use it.
const listener_interrupt_owner = Ref{Union{Nothing,ListenerInterrupt}}(nothing)

function listener_interrupt_callback(handle::Ptr{Cvoid}, signum::Cint)
    data = ccall(:uv_handle_get_data, Ptr{Cvoid}, (Ptr{Cvoid},), handle)
    owner = unsafe_pointer_to_objref(data)::ListenerInterrupt
    owner.requested[] = true
    return nothing
end

function listener_interrupt_close_callback(handle::Ptr{Cvoid})
    data = ccall(:uv_handle_get_data, Ptr{Cvoid}, (Ptr{Cvoid},), handle)
    owner = unsafe_pointer_to_objref(data)::ListenerInterrupt
    Libc.free(handle)
    owner.closed[] = true
    return nothing
end

function close_listener_interrupt!(owner::ListenerInterrupt)
    Base.iolock_begin()
    try
        if owner.handle != C_NULL
            ccall(:uv_signal_stop, Cint, (Ptr{Cvoid},), owner.handle)
            ccall(:uv_close, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), owner.handle,
                @cfunction(listener_interrupt_close_callback, Cvoid, (Ptr{Cvoid},)))
            owner.handle = C_NULL
        end
    finally
        Base.iolock_end()
    end
    timedwait(() -> owner.closed[], 5; pollint=0.01) == :ok ||
        error("listener interrupt handle did not close")
    listener_interrupt_owner[] === owner && (listener_interrupt_owner[] = nothing)
    return nothing
end

function start_listener_interrupt()
    # These Base helpers supply Julia's loop and serialize access to it. Do not
    # use a separate loop or call Julia code from a POSIX signal handler.
    Base.iolock_begin()
    owner = nothing
    start_result = 0
    try
        listener_interrupt_owner[] === nothing || error("a CLI listener already owns SIGINT")
        handle = Libc.malloc(Base.uv_sizeof_handle(Base.UV_SIGNAL))
        handle == C_NULL && throw(OutOfMemoryError())
        owner = ListenerInterrupt(handle, Threads.Atomic{Bool}(false), Threads.Atomic{Bool}(false))
        result = ccall(:uv_signal_init, Cint, (Ptr{Cvoid}, Ptr{Cvoid}), Base.eventloop(), handle)
        if result < 0
            Libc.free(handle)
            Base.uv_error("uv_signal_init", result)
        end
        listener_interrupt_owner[] = owner
        ccall(:uv_handle_set_data, Cvoid, (Ptr{Cvoid}, Any), handle, owner)
        start_result = ccall(:uv_signal_start, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Cint), handle,
            @cfunction(listener_interrupt_callback, Cvoid, (Ptr{Cvoid}, Cint)), Base.SIGINT)
    finally
        Base.iolock_end()
    end
    if start_result < 0
        close_listener_interrupt!(owner)
        Base.uv_error("uv_signal_start", start_result)
    end
    return owner
end
