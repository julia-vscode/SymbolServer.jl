module SymbolServer

using Pkg, SHA
using Base: UUID

current_package_name = ARGS[1]
current_package_version = VersionNumber(ARGS[2])
current_package_treehash = ARGS[3]

module LoadingBay
end

Pkg.add(name=current_package_name, version=current_package_version)

# TODO Make the code below ONLY write a cache file for the package we just added here.

include("faketypes.jl")
include("symbols.jl")
include("utils.jl")
include("serialize.jl")
using .CacheStore

# This path will always be mounted in the docker container in which we are running
store_path = "/symcache"

ctx = Pkg.Types.Context()

server = Server(store_path, ctx, Dict{UUID,Package}())

function write_cache(name, pkg)
    open(joinpath(server.storedir, name), "w") do io
        CacheStore.write(io, pkg)
    end
end

function write_depot(server, ctx)
    # TODO This should only ever have one entry now, so no loop needed, make sure that is the case
    for (uuid, pkg) in server.depot

        mkpath(joinpath(server.storedir, "v1", "packages", "$(current_package_name)_$uuid"))

        versionwithoutplus = replace(string(current_package_version), '+'=>'_')

        cache_path = joinpath(server.storedir, "v1", "packages", "$(current_package_name)_$uuid", "v_$(versionwithoutplus)_$current_package_treehash.jstore")

        write_cache(cache_path, pkg)
    end
end

try
    LoadingBay.eval(:(import $(Symbol(current_package_name))))
catch err
    exit(-10)
end

# Create image of whole package env. This creates the module structure only.
env_symbols = getenvtree()

# Populate the above with symbols, skipping modules that don't need caching.
# symbols (env_symbols)
visited = Base.IdSet{Module}([Base, Core]) # don't need to cache these each time...
for (pid, m) in Base.loaded_modules
    if pid.name !== current_package_name
        push!(visited, m)
        delete!(env_symbols, Symbol(pid.name))
    end
end

symbols(env_symbols, nothing, getallns(), visited)

# Wrap the `ModuleStore`s as `Package`s.
for (pkg_name, cache) in env_symbols
    pkg_name = String(pkg_name)
    !isinmanifest(ctx, pkg_name) && continue
    uuid = packageuuid(ctx, String(pkg_name))
    pe = frommanifest(ctx, uuid)
    server.depot[uuid] = Package(String(pkg_name), cache, uuid, sha_pkg(pe))
end

# Write to disc
write_depot(server, server.context)

end
