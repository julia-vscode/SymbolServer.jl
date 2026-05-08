module SymbolServer

using Pkg, SHA
using Base: UUID

# this is required to get parsedocs to work on Julia 1.11 and newer, since the implementation
# moved there
using REPL

current_package_name = Symbol(ARGS[1])
current_package_version = VersionNumber(ARGS[2])
current_package_uuid = UUID(ARGS[3])
current_package_treehash = ARGS[4]

@info "Indexing package $current_package_name $current_package_version..."

# /symcache is the historical Docker mount point used by the registry
# indexer; tests pass an explicit store_path as ARGS[5].
store_path = length(ARGS) >= 5 ? ARGS[5] : "/symcache"

current_package_versionwithoutplus = replace(string(current_package_version), '+'=>'_')
filename_with_extension = "v$(current_package_versionwithoutplus)_$current_package_treehash.jstore"

module LoadingBay end

# When invoked from tests, the package is already dev-deped in the active
# project; skip the registry round-trip in that case.
already_loadable = try
    Base.identify_package(string(current_package_name)) !== nothing
catch
    false
end

if !already_loadable
    try
        Pkg.add(name=string(current_package_name), version=current_package_version)
    catch err
        @info "Could not install package, exiting"
        exit(20)
    end
end

# TODO Make the code below ONLY write a cache file for the package we just added here.
include("faketypes.jl")
include("symbols.jl")
include("utils.jl")
include("serialize.jl")
using .CacheStore

# World stamp taken before the package itself loads. method_world(m) on any
# Method added during the import will be > world_before, which is how
# cache_new_methods! discovers overloads of functions defined elsewhere.
world_before = Base.get_world_counter()

# Load package
m = try
    LoadingBay.eval(:(import $current_package_name))
    getfield(LoadingBay, current_package_name)
catch e
    @info "Could not load package, exiting."
    exit(10)
end

# Get the symbols
env = getenvtree([current_package_name])
symbols(env, m, get_return_type=true)

# Pick up overloads of functions defined elsewhere (e.g. Base.show) that
# the package added without importing the name into its own module.
cache_new_methods!(env, world_before; get_return_type=true)

# Strip out paths
modify_dirs(env[current_package_name], f -> modify_dir(f, pkg_src_dir(Base.loaded_modules[Base.PkgId(current_package_uuid, string(current_package_name))]), "PLACEHOLDER"))

# There's an issue here - @enum used within CSTParser seems to add a method that is introduced from Enums.jl...

# Write them to a file
open(joinpath(store_path, filename_with_extension), "w") do io
    CacheStore.write(io, Package(string(current_package_name), env[current_package_name], current_package_uuid, nothing))
end

@info "Finished indexing."

# We are exiting with a custom error code to indicate success. This allows
# the parent process to distinguish between a successful run and one
# where the package exited the process.
exit(37)

end
