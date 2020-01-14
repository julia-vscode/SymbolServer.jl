module SymbolServer

export SymbolServerInstance, getstore

using Serialization, Pkg, SHA
using Base: UUID

include("utils.jl")
include("symbols.jl")

mutable struct SymbolServerInstance
    process::Union{Nothing,Base.Process}
    process_stderr::Union{IOBuffer,Nothing}
    depot_path::String

    function SymbolServerInstance(depot_path::String)
        return new(nothing, nothing, depot_path)
    end
end

function getstore(ssi::SymbolServerInstance, environment_path::AbstractString, result_channel)
    !ispath(environment_path) && error("Must specify an environment path.")

    jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
    server_script = joinpath(@__DIR__, "server.jl")

    env_to_use = copy(ENV)

    if ssi.depot_path==""
        delete!(env_to_use, "JULIA_DEPOT_PATH")
    else
        env_to_use["JULIA_DEPOT_PATH"] = ssi.depot_path
    end

    # stderr_for_client_process = VERSION < v"1.1.0" ? nothing : IOBuffer()    
    stderr_for_client_process = nothing

    if ssi.process!==nothing
        kill(ssi.process)
    end

    p = open(pipeline(Cmd(`$jl_cmd --startup-file=no --compiled-modules=no --history-file=no --project=$environment_path $server_script`, env = env_to_use), stderr = stderr_for_client_process), read = true, write = true)
    ssi.process = p
    ssi.process_stderr = stderr_for_client_process

    @async begin
        @info "Waiting for symbol server to finish"
        if success(p)
            @info "Symbol server finished."

            # Now we create a new symbol store and load everything into that
            # from disc
            new_store = deepcopy(stdlibs)
            load_project_packages_into_store!(ssi, environment_path, new_store)

            @info "Push store to channel."
            # Finally, we push the new store into the results channel
            # Clients can pick it up from there
            push!(result_channel, new_store)
            @info "getstore is finished."
        else
            @info "Symbol server failed."
        end
    end
        
    return
end

function load_project_packages_into_store!(ssi::SymbolServerInstance, environment_path, store)
    project_filename = isfile(joinpath(environment_path, "JuliaProject.toml")) ? joinpath(environment_path, "JuliaProject.toml") : joinpath(environment_path, "Project.toml")
    project = Pkg.API.read_project(project_filename)

    manifest_filename = isfile(joinpath(environment_path, "JuliaManifest.toml")) ? joinpath(environment_path, "JuliaManifest.toml") : joinpath(environment_path, "Manifest.toml")
    manifest = Pkg.API.read_manifest(joinpath(environment_path, "Manifest.toml"))

    for uuid in values(deps(project))
        load_package_from_cache_into_store!(ssi, uuid, manifest, store)
    end
end

"""
    load_package_from_cache_into_store!(ssp::SymbolServerInstance, uuid::UUID, store)

Tries to load the on-disc stored cache for a package (uuid). Attempts to generate (and save to disc) a new cache if the file does not exist or is unopenable.
"""
function load_package_from_cache_into_store!(ssi::SymbolServerInstance, uuid::UUID, manifest, store)
    storedir = abspath(joinpath(@__DIR__, "..", "store"))
    cache_path = joinpath(storedir, get_filename_from_name(manifest, uuid))

    if !isinmanifest(manifest, uuid)
        @info "Tried to load $uuid but failed to find it in the manifest."
        return
    end

    pe = frommanifest(manifest, uuid)
    pe_name = packagename(manifest, uuid)

    haskey(store, pe_name) && return

    @info "Loading $pe_name from cache."

    if isfile(cache_path)
        try
            package_data = open(cache_path) do io
                deserialize(io)
            end
            store[pe_name] = package_data.val
            for dep in deps(pe)
                load_package_from_cache_into_store!(ssi, packageuuid(dep), manifest, store)
            end
        catch err
            @info "Tried to load $pe_name but failed to load from disc, re-caching."
            rm(cache_path)
        end
    else
        @info "$(pe_name) not stored on disc"
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

const stdlibs = load_core()

end # module
