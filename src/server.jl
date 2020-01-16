module SymbolServer

# Try to lower the priority of this process so that it doesn't block the
# user system.
@static if Sys.iswindows()
    # Get process handle
    p_handle = ccall(:GetCurrentProcess, stdcall, Ptr{Cvoid}, ())

    # Set BELOW_NORMAL_PRIORITY_CLASS
    ret = ccall(:SetPriorityClass, stdcall, Cint, (Ptr{Cvoid}, Culong), p_handle, 0x00004000)
    ret!=1 && @warn "Something went wrong when setting BELOW_NORMAL_PRIORITY_CLASS."
else
    ret = ccall(:nice, Cint, (Cint, ), 1)
    # We don't check the return value because it doesn't really matter
end

module LoadingBay
end

using Serialization, Pkg, SHA
using Base: UUID

include("symbols.jl")
include("utils.jl")

server = Server(abspath(joinpath(@__DIR__, "..", "store")), Pkg.Types.Context(), Dict{Any,Any}())

function write_cache(name, pkg)
    open(joinpath(server.storedir, name), "w") do io
        serialize(io, pkg)
    end
end

# First get a list of all package UUIds that we want to cache
toplevel_pkgs = deps(project(Pkg.Types.Context()))

# Next make sure the cache is up-to-date for all of these
for (pk_name, uuid) in toplevel_pkgs
    cache_path = joinpath(server.storedir, get_filename_from_name(Pkg.Types.Context().env.manifest, uuid))

    if isfile(cache_path)
        if is_package_deved(Pkg.Types.Context().env.manifest, uuid)
            cached_version = open(cache_path) do io
                deserialize(io)
            end            

            if sha_pkg(frommanifest(Pkg.Types.Context().env.manifest, uuid)) != cached_version.sha
                @info "Now recaching package $pk_name ($uuid)"
                cache_package(server.context, uuid, server.depot)
            else
                @info "Package $pk_name ($uuid) is cached."
            end
        else            
            @info "Package $pk_name ($uuid) is cached."
        end
    else
        @info "Now caching package $pk_name ($uuid)"
        cache_package(server.context, uuid, server.depot)
    end
end

# Next write all package info to disc
for  (uuid, pkg) in server.depot
    cache_path = joinpath(server.storedir, get_filename_from_name(Pkg.Types.Context().env.manifest, uuid))

    @info "Now writing to disc $uuid"
    write_cache(cache_path, pkg)
end

end
