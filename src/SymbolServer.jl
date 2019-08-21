module SymbolServer
module LoadingBay
end
export SymbolServerProcess, disc_load_project

using Serialization, Pkg, SHA
using Base: UUID
@static if VERSION < v"1.1"
    const PackageEntry = Vector{Dict{String,Any}}
else
    using Pkg.Types: PackageEntry
end
include("symbols.jl")

mutable struct SymbolServerProcess
    context::Pkg.Types.Context
    depot::Dict{String,ModuleStore}
    function SymbolServerProcess(;c = Pkg.Types.Context())
        return new(c, deepcopy(stdlibs))
    end
end

function Base.show(io::IO, ssp::SymbolServerProcess)
    println(io, "SymbolServerProcess with $(length(ssp.depot)) ($(sum(!isempty(v.vals) for (k, v) in ssp.depot))) packages")

    print(join(sort!([string(isempty(v.vals) ? " ** " : "    ", k) for (k, v) in ssp.depot], lt = (a, b)->a[5:end] < b[5:end]), "\n"))
end

disc_load(context::Pkg.Types.Context, uuid::String, depot = Dict(), report = []) = disc_load(context, UUID(uuid), depot, report)

function disc_load(context::Pkg.Types.Context, uuid::UUID, depot = Dict(), report = Dict{UUID,String}())
    storedir = abspath(joinpath(@__DIR__, "..", "store"))
    cache_path = joinpath(storedir, string(uuid, ".jstore"))

    if !isinmanifest(context, uuid) && !isinproject(context, uuid)
        @info "Tried to load $uuid but failed to find it in the manifest."
        return
    end

    pe = frommanifest(context, uuid)
    pe_name = packagename(context, uuid)
    pe_name in keys(depot) && return depot, report
    if !isfile(cache_path)
        report[uuid] = "no file"
    else
        try
            store = open(cache_path) do io
                deserialize(io)
            end
            if version(pe) != store.ver || ((store.ver isa String && endswith(store.ver, "+") || (store.ver isa VersionNumber && (!isempty(store.ver.build) || !isempty(store.ver.prerelease)))) && sha_pkg(pe) != store.sha)
                @info "$pe_name changed, updating cache."
                report[uuid] = "outdated"
            else
                depot[pe_name] = store.val
            end
        catch err
            report[uuid] = "other"
            rm(cache_path)
        end

        for dep in deps(pe)
            disc_load(context, packageuuid(dep), depot, report)
        end
    end
    return depot, report
end

function disc_load_project(ssp::SymbolServerProcess)
    r = Dict{UUID,String}()
    for (n, u) in deps(ssp.context.env.project)
        SymbolServer.disc_load(ssp.context, u, ssp.depot, r)
    end
    return r
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
