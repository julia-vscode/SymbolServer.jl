module SymbolServer

export SymbolServerProcess
export getstore

using Serialization, Pkg, SHA

include("clientprocess/from_static_lint.jl")

mutable struct SymbolServerProcess
    process::Base.Process
    context::Union{Nothing,Pkg.Types.Context}
    depot::Dict{String,ModuleStore}
    process_stderr::Union{IOBuffer,Nothing}

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

        stderr_for_client_process = VERSION < v"1.1.0" ? nothing : IOBuffer()

        p = if environment===nothing
            open(pipeline(Cmd(`$jl_cmd $client_process_script`, env=env_to_use), stderr=stderr_for_client_process), read=true, write=true)
        else
            open(pipeline(Cmd(`$jl_cmd --project=$environment $client_process_script`, dir=environment, env=env_to_use), stderr=stderr_for_client_process), read=true, write=true)
        end
        ssp = new(p, nothing, Dict(), stderr_for_client_process)
        get_context(ssp)
        return ssp
    end
end

function request(server::SymbolServerProcess, message::Symbol, payload)
    serialize(server.process, (message, payload))
    ret_val = try
        deserialize(server.process)
    catch err
        # Only Julia 1.1 and newer support capturing stderr into an IOBuffer
        if server.process_stderr!==nothing
            stderr_from_client_process = String(take!(server.process_stderr))

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

function get_context(server::SymbolServerProcess)
    status, payload = request(server, :get_context, nothing)
    if status == :success
        server.context = payload
        return
    else
        error(payload)
    end
end

function load_store_from_disc(file::String)
    io = open(file)
    store = deserialize(io)
    close(io)
    typeof(store) != ModuleStore && @info "WARNING: Type mismatch in loaded store"
    return store
end

function shouldreload(pkgid, pkg, c)
    path = pkg_path(pkgid, c)
    isempty(path) && return false
    !endswith(pkg.ver, "+") && return false
    !isgitrepo(path) && return false
    return getgithash(path) != pkg.sha
end

function safe_load_store(pkg::PackageID, server::SymbolServerProcess, allowfail = true)
    storedir = abspath(joinpath(@__DIR__, "..", "store"))
    try
        server.depot[pkg.name] = load_store_from_disc(joinpath(storedir, "$(pkg.uuid).jstore"))
        !(server.depot[pkg.name] isa ModuleStore) && error("Type mismatch")

        if shouldreload(pkg, server.depot[pkg.name], server.context)
            parents = Base.UUID(pkg.uuid) in keys(server.context.env.manifest) ? [pkg] : find_parent(server.context, pkg.uuid)
            isempty(parents) && return
            loaded_pkgs = load_package(server, first(parents))
            for pkg1 in loaded_pkgs
                if haskey(server.context.env.manifest, Base.UUID(pkg1[1]))
                    safe_load_store(PackageID(pkg1[2], pkg1[1]), server, false)
                end
            end
        end
    catch e
        !allowfail && return
        parents = Base.UUID(pkg.uuid) in keys(server.context.env.manifest) ? [pkg] : find_parent(server.context, pkg.uuid)
        isempty(parents) && return
        loaded_pkgs = load_package(server, first(parents))
        for pkg1 in loaded_pkgs
            if haskey(server.context.env.manifest, Base.UUID(pkg1[1]))
                safe_load_store(PackageID(pkg1[2], pkg1[1]), server, false)
            end
        end
    end
end# loaded_pkgs = load_package(server, pkg)

# Public API

function getstore(server::SymbolServerProcess)
    storedir = abspath(joinpath(@__DIR__, "..", "store"))
    try
        server.depot["Base"] = load_store_from_disc(joinpath(storedir, "Base.jstore"))
        server.depot["Core"] = load_store_from_disc(joinpath(storedir, "Core.jstore"))
    catch e
        load_core(server)
        try
            server.depot["Base"] = load_store_from_disc(joinpath(storedir, "Base.jstore"))
            server.depot["Core"] = load_store_from_disc(joinpath(storedir, "Core.jstore"))
        catch e
            error("Couldn't load core stores")
        end
    end
    for pkg in get_manifest(server.context)
        pkg.name in keys(server.depot) && continue
        safe_load_store(pkg, server)
    end
    return server.depot
end

function Base.kill(server::SymbolServerProcess)
    serialize(server.process, (:close, nothing))
end

function load_core(server::SymbolServerProcess)
    status, payload = request(server, :load_core, nothing)
    if status == :success
        return payload
    else
        error(payload)
    end
end

function load_package(server::SymbolServerProcess, pkg::PackageID)
    status, payload = request(server, :load_package, (pkg.name, pkg.uuid))
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

function clear_disc_store()
    storedir = abspath(joinpath(@__DIR__, "..", "store"))
    for f in readdir(storedir)
        if endswith(f, ".jstore")
            rm(joinpath(storedir, f))
        end
    end
end

end # module
