module SymbolServer

import Sockets

pipename = length(ARGS) > 1 ? ARGS[2] : nothing

conn = pipename!==nothing ? Sockets.connect(pipename) : nothing

start_time = time_ns()

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

store_path = length(ARGS)>0 ? ARGS[1] : abspath(joinpath(@__DIR__, "..", "store"))

ctx = try
    Pkg.Types.Context()
catch err
    isa(err, Base.LoadError) || rethrow()
    @info "Package environment can't be read."
    exit()
end

server = Server(store_path, ctx, Dict{Any,Any}())

function write_cache(name, pkg)
    open(joinpath(server.storedir, name), "w") do io
        serialize(io, pkg)
    end
end
# List of caches that have already been written
written_caches = String[]

# First get a list of all package UUIds that we want to cache
toplevel_pkgs = deps(project(ctx))

# Next make sure the cache is up-to-date for all of these
for (pk_name, uuid) in toplevel_pkgs

    file_name = get_filename_from_name(ctx.env.manifest, uuid)

    # We sometimes have UUIDs in the project file that are not in the 
    # manifest file. That seems like something that shouldn't happen, but
    # in practice is not under our control. For now, we just skip these
    # packages
    file_name===nothing && continue

    cache_path = joinpath(server.storedir, file_name)

    if isfile(cache_path)
        if is_package_deved(ctx.env.manifest, uuid)
            cached_version = open(cache_path) do io
                deserialize(io)
            end            

            if sha_pkg(frommanifest(ctx.env.manifest, uuid)) != cached_version.sha
                @info "Now recaching package $pk_name ($uuid)"
                cache_package(server.context, uuid, server.depot, conn)
            else
                @info "Package $pk_name ($uuid) is cached."
            end
        else            
            @info "Package $pk_name ($uuid) is cached."
        end
    else
        @info "Now caching package $pk_name ($uuid)"
        cache_package(server.context, uuid, server.depot, conn)
        # Next write all package info to disc
        for  (uuid, pkg) in server.depot
            filename = get_filename_from_name(ctx.env.manifest, uuid)
            filename===nothing && continue
            cache_path = joinpath(server.storedir, filename)
            cache_path in written_caches && continue
            push!(written_caches, cache_path)
            @info "Now writing to disc $uuid"
            write_cache(cache_path, pkg)
        end
    end
end

end_time = time_ns()

elapsed_time_in_s = (end_time-start_time)/1e9
@info "Symbol server indexing took $elapsed_time_in_s seconds."

end
