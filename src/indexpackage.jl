
import SymbolServer

module LoadingBay end

if abspath(PROGRAM_FILE) == @__FILE__
    name = Symbol(ARGS[1])
    version = VersionNumber(ARGS[2])
    uuid = UUID(ARGS[3])
    treehash = ARGS[4]
    store_path = ARGS[5]

    # Load package
    m = try
        @time begin
            LoadingBay.eval(:(import $name))
            getfield(LoadingBay, name)
        end
    catch e
        @info "Could not load package $name $version ($uuid): $e"
        return 10
    end

    exit(SymbolServer.index_package(name, version, uuid, treehash, store_path, m))
end
