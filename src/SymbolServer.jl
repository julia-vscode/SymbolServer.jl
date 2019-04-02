module SymbolServer

export SymbolServerProcess
export getstore

using Serialization, Pkg, SHA

include("clientprocess/from_static_lint.jl")

mutable struct SymbolServerProcess
    process::Base.Process
    context::Union{Nothing,Pkg.Types.Context}
    depot::Dict{String,ModuleStore}

    function SymbolServerProcess(;environment=nothing, depot=nothing)
        jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
        client_process_script = joinpath(@__DIR__, "clientprocess", "clientprocess_main.jl")

        env_to_use = copy(ENV)

        if depot!==nothing
            if depot==""
                delete!(env_to_use, "JULIA_DEPOT_PATH")
            else
                env_to_use["JULIA_DEPOT_PATH"] = depot
            end
        end

        p = if environment===nothing
            open(Cmd(`$jl_cmd $client_process_script`, env=env_to_use), read=true, write=true)
        else
            open(Cmd(`$jl_cmd --project=$environment $client_process_script`, dir=environment, env=env_to_use), read=true, write=true)
        end
        ssp = new(p, nothing, Dict())
        get_context(ssp)
        return ssp
    end
end

function request(server::SymbolServerProcess, message::Symbol, payload)
    serialize(server.process, (message, payload))
    ret_val = deserialize(server.process)
    !(ret_val isa Tuple{Symbol,<:Any}) && error("Invalid response:\n", ret_val)
    return ret_val
end

function load_store_from_disc(file::String)
    io = open(file)
    store = deserialize(io)
    close(io)
    typeof(store) != ModuleStore && @info "WARNING: Type mismatch in loaded store"
    return store
end

function safe_load_store(pkg::Pkg.Types.PackageEntry, server::SymbolServerProcess, allowfail = true)
    storedir = abspath(joinpath(@__DIR__, "..", "store"))
    try 
        server.depot[pkg_name(pkg)] = load_store_from_disc(joinpath(storedir, "$(pkg_uuid(pkg)).jstore"))
        !(server.depot[pkg_name(pkg)] isa ModuleStore) && error("Type mismatch")
        # Check SHAs match
        if endswith(server.depot[pkg_name(pkg)].ver, "+") && pkg.path isa String && isdir(pkg.path) && get_dir_sha(pkg.path) != server.depot[pkg_name(pkg)].sha
            loaded_pkgs = load_package(server, pkg)
            for pkg1 in loaded_pkgs            
                if haskey(server.context.env.manifest, Base.UUID(pkg1[1]))
                    safe_load_store(server.context.env.manifest[Base.UUID(pkg1[1])], server, false)
                end
            end
        end
    catch e
        # @warn e
        loaded_pkgs = load_package(server, pkg)
        for pkg1 in loaded_pkgs
            
            if haskey(server.context.env.manifest, Base.UUID(pkg1[1]))
                safe_load_store(server.context.env.manifest[Base.UUID(pkg1[1])], server, false)
            end
        end
    end
end

# Public API

function getstore(server::SymbolServerProcess)
    storedir = abspath(joinpath(@__DIR__, "..", "store"))
    try
        server.depot["Base"] = load_store_from_disc(joinpath(storedir, "Base.jstore"))
        server.depot["Core"] = load_store_from_disc(joinpath(storedir, "Core.jstore"))
    catch e
        get_core_package(server)
        try
            server.depot["Base"] = load_store_from_disc(joinpath(storedir, "Base.jstore"))
            server.depot["Core"] = load_store_from_disc(joinpath(storedir, "Core.jstore"))
        catch e
            error("Couldn't load core stores")
        end
    end
    
    for pkg in server.context.env.manifest
        pkg_name(pkg[2]) in keys(server.depot) && continue
        safe_load_store(pkg[2], server)
    end

    return server.depot
end

function Base.kill(server::SymbolServerProcess)
    serialize(server.process, (:close, nothing))
end

function get_core_package(server::SymbolServerProcess)
    status, payload = request(server, :get_core_packages, nothing)
    if status == :success
        return payload
    else
        error(payload)
    end
end

function get_context(server::SymbolServerProcess)
    status, payload = request(server, :get_context, nothing)
    if status == :success
        server.context = payload
        return 
    else
        error(payload)
    end
end

function load_package(server::SymbolServerProcess, pkg::Pkg.Types.PackageEntry)
    status, payload = request(server, :load_package, pkg)
    if status == :success
        return payload
    else
        error(payload)
    end
end

function load_all(server::SymbolServerProcess)
    status, payload = request(server, :load_all, nothing)
    if status == :success
        return payload
    else
        error(payload)
    end
end

end # module
