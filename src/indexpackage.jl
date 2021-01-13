using Pkg, SHA
using Base: UUID

current_package_name = ARGS[1]
current_package_version = VersionNumber(ARGS[2])
current_package_treehash = ARGS[3]

module LoadingBay end
Pkg.add(name=current_package_name, version=current_package_version)


# TODO Make the code below ONLY write a cache file for the package we just added here.
include("faketypes.jl")
include("symbols.jl")
include("utils.jl")
include("serialize.jl")
using .CacheStore

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
env = getenvtree([Symbol(current_package_name)])
symbols(env, m)

# Write them to a file
ctx = Pkg.Types.Context()
uuid = packageuuid(ctx, current_package_name)
modify_dirs(env[Symbol(current_package_name)], f -> modify_dir(f, pkg_src_dir(Base.loaded_modules[Base.PkgId(uuid, current_package_name)]), "PLACEHOLDER")) # Strip out paths
# There's an issue here - @enum used within CSTParser seems to add a method that is introduced from Enums.jl...
mkpath(joinpath(store_path, "v1", "packages", "$(current_package_name)_$uuid"))
versionwithoutplus = replace(string(current_package_version), '+'=>'_')
cache_path = joinpath(store_path, "v1", "packages", "$(current_package_name)_$uuid", "v_$(versionwithoutplus)_$current_package_treehash.jstore")
open(cache_path, "w") do io
    CacheStore.write(io, Package(current_package_name, env[Symbol(current_package_name)], uuid, nothing))
end
