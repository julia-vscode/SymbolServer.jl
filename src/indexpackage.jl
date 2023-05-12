module SymbolServer

using Pkg, SHA
using Base: UUID

@time "Initial includes" begin
    include("faketypes.jl")
    include("symbols.jl")
    include("utils.jl")
    include("serialize.jl")
    using .CacheStore
end

module LoadingBay end

function index_package(name, version, uuid, treehash)
    @time "Indexing package $name $version..." begin
        versionwithoutplus = replace(string(version), '+'=>'_')
        filename_with_extension = "v$(versionwithoutplus)_$treehash.jstore"

        # Load package
        m = try
            @time "Loading $name $version" begin
                LoadingBay.eval(:(import $name))
                getfield(LoadingBay, name)
            end
        catch e
            @info "Could not load package $name $version ($uuid): $e"
            return 10
        end

        # Get the symbols
        env = @time "getenvtree" getenvtree([name])
        @time "symbols" symbols(env, m, get_return_type=true)

        # Strip out paths
        @time "modify_dirs" begin
            modify_dirs(
                env[name],
                f -> modify_dir(f, pkg_src_dir(Base.loaded_modules[Base.PkgId(uuid, string(name))]), "PLACEHOLDER")
            )
        end

        # The destination path must be where SymbolServer.jl expects it
        dir = joinpath(
            store_path,
            string(uppercase(string(name)[1])),
            string(name, "_", uuid),
        )

        mkpath(dir)

        @time "CacheStore.write" begin
            open(joinpath(dir, filename_with_extension), "w") do io
                CacheStore.write(io, Package(string(name), env[name], uuid, nothing))
            end
        end
    end

    # Exit with a custom error code to indicate success. This allows
    # the parent process to distinguish between a successful run and one
    # where the package exited the process.
    return 37
end

if abspath(PROGRAM_FILE) == @__FILE__
    name = Symbol(ARGS[1])
    version = VersionNumber(ARGS[2])
    uuid = UUID(ARGS[3])
    treehash = ARGS[4]
    store_path = ARGS[5]

    exit(index_package(name, version, uuid, treehash))
end

end
