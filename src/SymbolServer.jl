module SymbolServer

export SymbolServerInstance, getstore

using Pkg, SHA
using Base: UUID, Process
import Sockets, UUIDs

include("faketypes.jl")
include("symbols.jl")
include("utils.jl")
include("serialize.jl")
using .CacheStore

mutable struct SymbolServerInstance
    process::Union{Nothing,Base.Process}
    depot_path::String
    canceled_processes::Set{Process}
    store_path::String

    function SymbolServerInstance(depot_path::String="", store_path::Union{String,Nothing}=nothing)
        return new(nothing, depot_path, Set{Process}(), store_path === nothing ? abspath(joinpath(@__DIR__, "..", "store")) : store_path)
    end
end

function getstore(ssi::SymbolServerInstance, environment_path::AbstractString, progress_callback=nothing, error_handler=nothing; download = false)
    !ispath(environment_path) && return :success, recursive_copy(stdlibs)

    # see if we can download any package cache's before
    if download
        manifest_filename = toml_path(environment_path, Base.manifest_names)
        if isfile(manifest_filename)
            let manifest = read_manifest(manifest_filename)
                if manifest !== nothing
                    @debug "Downloading cache files for manifest at $(manifest_filename)."
                    asyncmap(collect(validate_disc_store(ssi.store_path, manifest)), ntasks = 10) do pkg
                        uuid = packageuuid(pkg)
                        get_file_from_cloud(manifest, uuid, environment_path, ssi.depot_path, ssi.store_path, ssi.store_path)
                    end
                end
            end
        end
    end


    jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
    server_script = joinpath(@__DIR__, "server.jl")

    env_to_use = copy(ENV)
    env_to_use["JULIA_REVISE"] = "manual" # Try to make sure Revise isn't enabled.

    if ssi.depot_path == ""
        delete!(env_to_use, "JULIA_DEPOT_PATH")
    else
        env_to_use["JULIA_DEPOT_PATH"] = ssi.depot_path
    end

    stderr_for_client_process = VERSION < v"1.1.0" ? nothing : IOBuffer()

    if ssi.process !== nothing
        to_cancel_p = ssi.process
        ssi.process = nothing
        push!(ssi.canceled_processes, to_cancel_p)
        kill(to_cancel_p)
    end

    use_code_coverage = Base.JLOptions().code_coverage

    currently_loading_a_package = false
    current_package_name = ""

    pipename = Sys.iswindows() ? "\\\\.\\pipe\\vscjlsymserv-$(UUIDs.uuid4())" : joinpath(tempdir(), "vscjlsymserv-$(UUIDs.uuid4())")

    server_is_ready = Channel(1)

    @async try
        server = Sockets.listen(pipename)

        put!(server_is_ready, nothing)

        conn = Sockets.accept(server)

        s = readline(conn)

        while s != "" && isopen(conn)
            parts = split(s, ';')
            if parts[1] == "STARTLOAD"
                currently_loading_a_package = true
                current_package_name = parts[2]
                current_package_uuid = parts[3]
                current_package_version = parts[4]
                progress_callback !== nothing && progress_callback(current_package_name)
            elseif parts[1] == "STOPLOAD"
                currently_loading_a_package = false
            elseif parts[1] == "PROCESSPKG"
                progress_callback !== nothing && progress_callback(parts[2])
            else
                error("Unknown command.")
            end
            s = readline(conn)
        end
    catch err
        bt = catch_backtrace()
        if error_handler !== nothing
            error_handler(err, bt)
        else
            Base.display_error(stderr, err, bt)
        end
    end

    take!(server_is_ready)

    p = open(pipeline(Cmd(`$jl_cmd --code-coverage=$(use_code_coverage==0 ? "none" : "user") --startup-file=no --compiled-modules=no --history-file=no --project=$environment_path $server_script $(ssi.store_path) $pipename`, env=env_to_use), stderr=stderr_for_client_process), read=true, write=true)
    ssi.process = p

    if success(p)
        # Now we create a new symbol store and load everything into that
        # from disc
        new_store = recursive_copy(stdlibs)
        load_project_packages_into_store!(ssi, environment_path, new_store)

        return :success, new_store
    elseif p in ssi.canceled_processes
        delete!(ssi.canceled_processes, p)

        return :canceled, nothing
    else
        if currently_loading_a_package
            return :package_load_crash, (package_name = current_package_name, stderr = stderr_for_client_process)
        else
            return :failure, stderr_for_client_process
        end
    end
end

function load_project_packages_into_store!(ssi::SymbolServerInstance, environment_path, store)
    project_filename = toml_path(environment_path, Base.project_names)
    project = try
        Pkg.API.read_project(project_filename)
    catch err
        @warn "Could not load project."
        return
    end

    manifest_filename = toml_path(environment_path, Base.manifest_names)
    manifest = read_manifest(manifest_filename)
    manifest === nothing && return

    for uuid in values(deps(project))
        load_package_from_cache_into_store!(ssi, uuid, manifest, store)
    end
end

"""
    load_package_from_cache_into_store!(ssp::SymbolServerInstance, uuid, store)

Tries to load the on-disc stored cache for a package (uuid). Attempts to generate (and save to disc) a new cache if the file does not exist or is unopenable.
"""
function load_package_from_cache_into_store!(ssi::SymbolServerInstance, uuid, manifest, store)
    isinmanifest(manifest, uuid) || return
    pe = frommanifest(manifest, uuid)
    pe_name = packagename(manifest, uuid)
    haskey(store, Symbol(pe_name)) && return

    # further existence checks needed?
    cache_path = joinpath(ssi.store_path, get_cache_path(manifest, uuid)...)
    if isfile(cache_path)
        try
            package_data = open(cache_path) do io
                CacheStore.read(io)
            end
            store[Symbol(pe_name)] = package_data.val
            for dep in deps(pe)
                load_package_from_cache_into_store!(ssi, packageuuid(dep), manifest, store)
            end
        catch err
            Base.display_error(stderr, err, catch_backtrace())
            @warn "Tried to load $pe_name but failed to load from disc, re-caching."
            try
                rm(cache_path)
            catch err2
                # There could have been a race condition that the file has been deleted in the meantime,
                # we don't want to crash then.
                err2 isa Base.IOError || rethrow(err2)
            end
        end
    else
        @warn "$(pe_name) not stored on disc"
        store[Symbol(pe_name)] = ModuleStore(VarRef(nothing, Symbol(pe_name)), Dict{Symbol,Any}(), "$pe_name failed to load.", true, Symbol[], Symbol[])
    end
end

function clear_disc_store(ssi::SymbolServerInstance)
    for f in readdir(ssi.store_path)
        if occursin(f, "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            rm(joinpath(ssi.store_path, f), recursive = true)
        end
    end
end

const stdlibs = load_core()

function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    Base.precompile(Tuple{Type{SymbolServer.DataTypeStore},SymbolServer.FakeTypeName,SymbolServer.FakeTypeName,Array{Any,1},Array{Any,1},Array{Symbol,1},Array{Any,1},String,Bool})
    Base.precompile(Tuple{typeof(SymbolServer.cache_methods),Any,Dict{Symbol,SymbolServer.ModuleStore}})
    Base.precompile(Tuple{typeof(SymbolServer.getenvtree)})
    Base.precompile(Tuple{typeof(SymbolServer.symbols),Dict{Symbol,SymbolServer.ModuleStore}})
    Base.precompile(Tuple{typeof(copy),Base.Broadcast.Broadcasted{Base.Broadcast.Style{Tuple},Nothing,typeof(SymbolServer._parameter),Tuple{NTuple{4,Symbol}}}})
end
VERSION >= v"1.4.2" && _precompile_()

end # module
