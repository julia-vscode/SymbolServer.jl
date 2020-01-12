module SymbolServer

module LoadingBay
end

using Serialization, Pkg, SHA
using Base: UUID

@static if VERSION < v"1.1"
    const PackageEntry = Vector{Dict{String,Any}}
else
    using Pkg.Types: PackageEntry
end

include("symbols.jl")
include("utils.jl")

server = Server(abspath(joinpath(@__DIR__, "..", "store")), Pkg.Types.Context(), Dict{Any,Any}())

function write_cache(uuid, pkg)
    open(joinpath(server.storedir, "$uuid.jstore"), "w") do io
        serialize(io, pkg)
    end
end

# First get a list of all package UUIds that we want to cache
toplevel_pkgs = deps(project(Pkg.Types.Context()))

# Next make sure the cache is up-to-date for all of these
for (pk_name, uuid) in toplevel_pkgs
    if isfile(joinpath(server.storedir, "$uuid.jstore"))
        @info "Package $pk_name ($uuid) is cached."
    else
        @info "Now caching package $pk_name ($uuid)"
        cache_package(server.context, uuid, server.depot)
    end
end

# Next write all package info to disc
for  (uuid, pkg) in server.depot
    @info "Now writing to disc $uuid"
    write_cache(uuid, pkg)
end

end
