using Pkg, SHA
using Base: UUID

current_package_name = ARGS[1]
current_package_version = VersionNumber(ARGS[2])
current_package_treehash = ARGS[3]

module LoadingBay end
Pkg.add(name=current_package_name, version=current_package_version)


# TODO Make the code below ONLY write a cache file for the package we just added here.
include("./SymbolServer.jl")

# This path will always be mounted in the docker container in which we are running
store_path = "/tmp/symcache"

# Load package
m = try
    LoadingBay.eval(:(import $(Symbol(current_package_name))))
    getfield(LoadingBay, Symbol(current_package_name))
catch e
    exit(-10)
end

# Get the symbols
env = SymbolServer.getenvtree([Symbol(current_package_name)])
SymbolServer.symbols(env, m)

# Write them to a file
ctx = Pkg.Types.Context()
uuid = SymbolServer.packageuuid(ctx, current_package_name)
mkpath(joinpath(store_path, "v1", "packages", "$(current_package_name)_$uuid"))
versionwithoutplus = replace(string(current_package_version), '+'=>'_')
cache_path = joinpath(store_path, "v1", "packages", "$(current_package_name)_$uuid", "v$(versionwithoutplus)_$current_package_treehash.jstore")
open(cache_path, "w") do io
    SymbolServer.CacheStore.write(io, SymbolServer.Package(current_package_name, env[Symbol(current_package_name)], uuid, nothing))
end
