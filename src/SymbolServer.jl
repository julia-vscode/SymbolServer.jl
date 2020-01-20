module SymbolServer

export SymbolServerInstance, getstore

using Serialization, Pkg, SHA
using Base: UUID, Process

include("symbols.jl")
include("utils.jl")

mutable struct SymbolServerInstance
    process::Union{Nothing,Base.Process}
    depot_path::String
    canceled_processes::Set{Process}
    store_path::String

    function SymbolServerInstance(depot_path::String="", store_path::String=abspath(joinpath(@__DIR__, "..", "store")))
        return new(nothing, depot_path, Set{Process}(), store_path)
    end
end

function getstore(ssi::SymbolServerInstance, environment_path::AbstractString)
    !ispath(environment_path) && error("Must specify an environment path.")

    jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
    server_script = joinpath(@__DIR__, "server.jl")

    env_to_use = copy(ENV)

    if ssi.depot_path==""
        delete!(env_to_use, "JULIA_DEPOT_PATH")
    else
        env_to_use["JULIA_DEPOT_PATH"] = ssi.depot_path
    end

    stderr_for_client_process = VERSION < v"1.1.0" ? nothing : IOBuffer()    

    if ssi.process!==nothing
        to_cancel_p = ssi.process
        ssi.process = nothing
        push!(ssi.canceled_processes, to_cancel_p)
        kill(to_cancel_p)
    end

    use_code_coverage = Base.JLOptions().code_coverage

    p = open(pipeline(Cmd(`$jl_cmd --code-coverage=$(use_code_coverage==0 ? "none" : "user") --startup-file=no --compiled-modules=no --history-file=no --project=$environment_path $server_script $(ssi.store_path)`, env = env_to_use), stderr = stderr_for_client_process), read = true, write = true)
    ssi.process = p

    @info "Waiting for symbol server to finish"
    if success(p)
        @info "Symbol server finished."

        # Now we create a new symbol store and load everything into that
        # from disc
        new_store = deepcopy(stdlibs)
        load_project_packages_into_store!(ssi, environment_path, new_store)

        @info "Successfully loaded store from disc."
        return :success, new_store
    elseif p in ssi.canceled_processes
        @info "Symbol server was canceled."
        delete!(ssi.canceled_processes, p)
        
        return :canceled, nothing
    else
        @info "Symbol server failed."
        return :failure, stderr_for_client_process
    end
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
    load_package_from_cache_into_store!(ssp::SymbolServerInstance, uuid, store)

Tries to load the on-disc stored cache for a package (uuid). Attempts to generate (and save to disc) a new cache if the file does not exist or is unopenable.
"""
function load_package_from_cache_into_store!(ssi::SymbolServerInstance, uuid, manifest, store)
    cache_path = joinpath(ssi.store_path, get_filename_from_name(manifest, uuid))

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
            Base.display_error(stderr, err, catch_backtrace())
            @info "Tried to load $pe_name but failed to load from disc, re-caching."
            rm(cache_path)
        end
    else
        @info "$(pe_name) not stored on disc"
    end
end

function clear_disc_store(ssi::SymbolServerInstance)
    for f in readdir(ssi.store_path)
        if endswith(f, ".jstore")
            rm(joinpath(ssi.store_path, f))
        end
    end
end

const stdlibs = load_core()

end # module
