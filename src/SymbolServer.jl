module SymbolServer

export SymbolServerProcess, change_env, load_manifest_packages, load_project_packages, get_context, getstore

using Serialization, Pkg, SHA
using Base: UUID
@static if VERSION < v"1.1"
    const PackageEntry = Vector{Dict{String,Any}}
else
    using Pkg.Types: PackageEntry
end
include("symbols.jl")

mutable struct SymbolServerProcess
    process::Base.Process
    context::Union{Nothing,Pkg.Types.Context}
    depot::Dict{String,ModuleStore}
    process_stderr::Union{IOBuffer,Nothing}
    
    caching_packages::Set{UUID}
    newly_cached_packages::Vector{UUID}

    function SymbolServerProcess(;environment = nothing, depot = nothing)
        jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
        server_script = joinpath(@__DIR__, "server.jl")

        env_to_use = copy(ENV)
        if depot !== nothing
            if depot == ""
                delete!(env_to_use, "JULIA_DEPOT_PATH")
            else
                env_to_use["JULIA_DEPOT_PATH"] = depot
            end
        end

        stderr_for_client_process = VERSION < v"1.1.0" ? nothing : IOBuffer()

        p = if environment === nothing
            open(pipeline(Cmd(`$jl_cmd $server_script`, env = env_to_use), stderr = stderr_for_client_process), read = true, write = true)
        else
            open(pipeline(Cmd(`$jl_cmd --project=$environment $server_script`, dir = environment, env = env_to_use), stderr = stderr_for_client_process), read = true, write = true)
        end
        ssp = new(p, nothing, deepcopy(stdlibs), stderr_for_client_process, Set{UUID}(), UUID[])
        get_context(ssp)
        return ssp
    end
end

function Base.show(io::IO, ssp::SymbolServerProcess)
    println(io, "SymbolServerProcess with $(length(ssp.depot)) packages")
    for (k, v) in ssp.depot
        println(io, isempty(v.vals) ? " ** " : "    ", k)
    end
end


function request(ssp::SymbolServerProcess, message::Symbol, payload)
    serialize(ssp.process, (message, payload))
    ret_val = try
        deserialize(ssp.process)
    catch err
        # Only Julia 1.1 and newer support capturing stderr into an IOBuffer
        if ssp.process_stderr !== nothing
            stderr_from_client_process = String(take!(ssp.process_stderr))

            complete_error_message = string(sprint(showerror, err), "\n\nstderr from client process:\n\n", stderr_from_client_process)

            error(complete_error_message)
        else
            complete_error_message = string(sprint(showerror, err), "\n\nCouldn't capture stderr from client process on julia 1.0.\n\n")

            error(complete_error_message)
        end
    end

    !(ret_val isa Tuple{Symbol,<:Any}) && error("Invalid response:\n", ret_val)
    return ret_val
end

"""
    load_manifest_packages(ssp)
Load all packages from the current active environments manifest into the client
side depot.
"""
function load_manifest_packages(ssp::SymbolServerProcess)
    # for uuid in keys(manifest(ssp.context))
    for pkg in manifest(ssp.context)
        load_package_cache(ssp, packageuuid(pkg))
    end
    update(ssp)
end

function load_project_packages(ssp::SymbolServerProcess)
    for uuid in values(deps(project(ssp.context)))
        load_package_cache(ssp, uuid)
    end
    update(ssp)
end

function getstore(ssp::SymbolServerProcess)
    load_manifest_packages(ssp)
    return ssp.depot
end

"""
    get_context(ssp)
Retrieves the active context (environment) from the server.
"""
function get_context(ssp::SymbolServerProcess)
    status, payload = request(ssp, :get_context, nothing)
    if status == :success
        ssp.context = payload
        return
    else
        error(payload)
    end
end
"""
    change_env(ssp, env_path)
Activates a new environment on the server. The new active context must then be retrieved separately.
"""
function change_env(ssp::SymbolServerProcess, env_path::String)
    status, payload = request(ssp, :change_env, env_path)
    if status == :success
        return payload
    else
        error(payload)
    end
end


"""
    load_package_cache(ssp::SymbolServerProcess, uuid::UUID)
Tries to load the on-disc stored cache for a package (uuid). Attempts to generate (and save to disc) a new cache if the file does not exist or is unopenable.
"""
function load_package_cache(ssp::SymbolServerProcess, uuid::UUID)
    storedir = abspath(joinpath(@__DIR__, "..", "store"))
    cache_path = joinpath(storedir, string(uuid, ".jstore"))
    # if !(uuid in keys(manifest(ssp.context)))
    if !isinmanifest(ssp.context, uuid)
        return 
    end

    pe = frommanifest(ssp.context, uuid)
    pe_name = packagename(ssp.context, uuid)
    if isfile(cache_path)
        try
            store = open(cache_path) do io
                deserialize(io)
            end
            if version(pe) != store.ver || (store.ver isa String && endswith(store.ver, "+") && sha_pkg(pe) != store.sha)
            end
            ssp.depot[pe_name] = store.val
        catch err
            if err isa UndefVarError && err.var in (:structStore, :abstractStore)
                @info "Package cache pre-v3.0"
            end
            rm(cache_path)
            cache_package(ssp, uuid)
        end
    else
        @info "$(pe_name) not stored on disc"
        cache_package(ssp, uuid)
    end
end

load_package_cache(ssp::SymbolServerProcess, uuid::String) = load_package_cache(ssp, UUID(uuid))

function Base.kill(server::SymbolServerProcess)
    serialize(server.process, (:close, nothing))
end
"""
    cache_package(ssp, uuid::Union{UUID, Vector{UUID}})
Sends a request to the server to cache a package or collection of packages. 
Requested packages are added to the list `ssp.caching_packages` to prevent the
sending multiple requests for the same package. 
    
The server returns a list of packages that it has loaded and adds it to 
`ssp.newly_cached_packages`. This list should be used to `update` the client side
depot `ssp.depot`.
"""
cache_package(ssp::SymbolServerProcess, uuid::UUID) = cache_package(ssp, [uuid])
function cache_package(ssp::SymbolServerProcess, uuid::Vector{UUID})
    if uuid in ssp.caching_packages
        return
    end
    union!(ssp.caching_packages, uuid)
    status, payload = request(ssp, :cache_package, string.(uuid))
    if status == :success
        delete!(ssp.caching_packages, uuid)
        append!(ssp.newly_cached_packages, UUID.(payload))
        return payload
    else
        error(payload)
    end
end

"""
    update(ssp)
Update the client side depot with newly cached packages.
"""
function update(ssp::SymbolServerProcess)
    for uuid in ssp.newly_cached_packages
        load_package_cache(ssp, uuid)
    end
end

function clear_disc_store()
    storedir = abspath(joinpath(@__DIR__, "..", "store"))
    for f in readdir(storedir)
        if endswith(f, ".jstore")
            rm(joinpath(storedir, f))
        end
    end
end
include("utils.jl")
const stdlibs = load_core()
end # module
