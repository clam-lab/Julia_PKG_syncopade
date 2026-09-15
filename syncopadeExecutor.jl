# Task loading and function cache. Including this file does not start a process.
const DEFAULT_UNIX_MOUNT_ROOT = "/Volumes/syncopade_nfs"
const DEFAULT_WINDOWS_MOUNT_ROOT = raw"\\192.168.100.96\syncopade_nfs"
const DEFAULT_FUNCTION_CACHE_SIZE = 10
const function_cache_lock = ReentrantLock()
const include_lock = ReentrantLock()
const function_cache = Dict{Tuple{String,String,String}, Function}()
const function_cache_lru = Tuple{String,String,String}[]

function clear_function_cache!()::Int
    lock(function_cache_lock) do
        cleared = length(function_cache_lru)
        empty!(function_cache)
        empty!(function_cache_lru)
        return cleared
    end
end

function configured_function_cache_size()::Int
    raw = strip(get(ENV, "SYNCOPADE_FUNCTION_CACHE_SIZE", string(DEFAULT_FUNCTION_CACHE_SIZE)))
    size = tryparse(Int, raw)
    if size === nothing
        return DEFAULT_FUNCTION_CACHE_SIZE
    end
    return max(size, 0)
end

function configured_mount_root()::String
    if Sys.iswindows()
        return get(ENV, "SYNCOPADE_MOUNT_ROOT_WINDOWS", DEFAULT_WINDOWS_MOUNT_ROOT)
    end
    return get(ENV, "SYNCOPADE_MOUNT_ROOT_UNIX", DEFAULT_UNIX_MOUNT_ROOT)
end

function path_norm_compare(path::String)::String
    p = normpath(path)
    p = replace(p, '\\' => '/')
    return Sys.iswindows() ? lowercase(p) : p
end

function is_under_root(path::String, root::String)::Bool
    path_cmp = path_norm_compare(path)
    root_cmp = path_norm_compare(root)
    return path_cmp == root_cmp || startswith(path_cmp, root_cmp * "/")
end

function ensure_jl_extension(path::AbstractString)::String
    p = String(path)
    return endswith(lowercase(p), ".jl") ? p : p * ".jl"
end

function source_basename(path::AbstractString)::String
    normalized = replace(path, '\\' => '/')
    parts = split(normalized, '/')
    return isempty(parts) ? String(path) : String(parts[end])
end

function resolve_source_script_path(file_name::String, mount_root::String)::String
    source = strip(file_name)
    isempty(source) && throw(ArgumentError("Empty source file name"))

    has_sep = occursin('/', source) || occursin('\\', source)
    candidates = String[]
    if has_sep
        push!(candidates, ensure_jl_extension(source))
        push!(candidates, ensure_jl_extension(joinpath(mount_root, source_basename(source))))
    else
        push!(candidates, ensure_jl_extension(joinpath(mount_root, source)))
        push!(candidates, ensure_jl_extension(source))
    end

    for script_path in unique(candidates)
        if is_under_root(script_path, mount_root) && !isdir(mount_root)
            throw(ArgumentError("Required mount is missing: $(mount_root)"))
        end
        if isfile(script_path)
            return script_path
        end
    end

    throw(ArgumentError("Source script not found. requested=$(file_name) candidates=$(join(candidates, ", "))"))
end

function cache_lookup_function(key::Tuple{String,String,String})::Union{Nothing,Function}
    max_size = configured_function_cache_size()
    max_size <= 0 && return nothing

    lock(function_cache_lock) do
        f = get(function_cache, key, nothing)
        if f === nothing
            return nothing
        end

        idx = findfirst(isequal(key), function_cache_lru)
        if idx !== nothing
            deleteat!(function_cache_lru, idx)
        end
        pushfirst!(function_cache_lru, key)
        return f
    end
end

function cache_store_function!(key::Tuple{String,String,String}, f::Function)::Function
    max_size = configured_function_cache_size()
    max_size <= 0 && return f

    lock(function_cache_lock) do
        existing = get(function_cache, key, nothing)
        if existing !== nothing
            idx = findfirst(isequal(key), function_cache_lru)
            if idx !== nothing
                deleteat!(function_cache_lru, idx)
            end
            pushfirst!(function_cache_lru, key)
            return existing
        end

        function_cache[key] = f
        idx = findfirst(isequal(key), function_cache_lru)
        if idx !== nothing
            deleteat!(function_cache_lru, idx)
        end
        pushfirst!(function_cache_lru, key)

        while length(function_cache_lru) > max_size
            evicted_key = pop!(function_cache_lru)
            delete!(function_cache, evicted_key)
        end

        return f
    end
end

function load_remote_function(script_path::String, module_name::String, func_name::String)::Function
    lock(include_lock) do
        include(script_path)
        mod = Base.invokelatest(getfield, Main, Symbol(module_name))
        return Base.invokelatest(getfield, mod, Symbol(func_name))
    end
end


# リモートから指定されたプログラムファイルを開いて関数を実行する
# args はすべて String として渡される
# 型変換は呼び出される関数側で行う
# 呼び出しの戻り値はそのまま返される．Stringを返すこと
function call_func(file_name::String, module_name::String, func_name::String, args::Vector{String}=String[])
    required_mount_root = configured_mount_root()
    script_path = resolve_source_script_path(file_name, required_mount_root)
    key = (script_path, module_name, func_name)
    f = cache_lookup_function(key)
    if f === nothing
        loaded = load_remote_function(script_path, module_name, func_name)
        f = cache_store_function!(key, loaded)
    end

    return Base.invokelatest(f, args...) 
end
