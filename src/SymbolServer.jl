module SymbolServer

export SymbolServerInstance, getstore

using Pkg, SHA
using Base: UUID, Process
import Sockets, UUIDs

include("faketypes.jl")
include("symbols.jl")
include("utils.jl")
include("serialize.jl")
using .CacheStore

export index_package, index_packages

mutable struct SymbolServerInstance
    process::Union{Nothing,Base.Process}
    depot_path::String
    canceled_processes::Set{Process}
    store_path::String
    symbolcache_upstream::String

    function SymbolServerInstance(depot_path::String="", store_path::Union{String,Nothing}=nothing; symbolcache_upstream = nothing)
        if symbolcache_upstream === nothing
            symbolcache_upstream = "https://www.julia-vscode.org/symbolcache"
        end
        return new(nothing, depot_path, Set{Process}(), store_path === nothing ? abspath(joinpath(@__DIR__, "..", "store")) : store_path, symbolcache_upstream)
    end
end

function getstore(ssi::SymbolServerInstance, environment_path::AbstractString, progress_callback=nothing, error_handler=nothing; download = false)
    !ispath(environment_path) && return :success, recursive_copy(stdlibs)

    # see if we can download any package cache's before
    if download
        download_dir_parent = joinpath(ssi.store_path, "_downloads")
        mkpath(download_dir_parent)

        mktempdir(download_dir_parent) do download_dir
            manifest_filename = isfile(joinpath(environment_path, "JuliaManifest.toml")) ? joinpath(environment_path, "JuliaManifest.toml") : joinpath(environment_path, "Manifest.toml")
            if isfile(manifest_filename)
                let manifest = read_manifest(manifest_filename)
                    if manifest !== nothing
                        @debug "Downloading cache files for manifest at $(manifest_filename)."
                        to_download = collect(validate_disk_store(ssi.store_path, manifest))
                        batches = Iterators.partition(to_download, max(1, floor(Int, length(to_download)÷50)))
                        for (i, batch) in enumerate(batches)
                            percentage = round(Int, 100*(i - 1)/length(batches))
                            progress_callback !== nothing && progress_callback("Downloading caches...", percentage)
                            @sync for pkg in batch
                                @async begin
                                    yield()
                                    uuid = packageuuid(pkg)
                                    get_file_from_cloud(manifest, uuid, environment_path, ssi.depot_path, ssi.store_path, download_dir, ssi.symbolcache_upstream)
                                    yield()
                                end
                            end
                        end
                        progress_callback !== nothing && progress_callback("All cache files downloaded.", 100)
                    end
                end
            end
        end
    end

    jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
    server_script = joinpath(@__DIR__, "server.jl")

    env_to_use = copy(ENV)
    env_to_use["JULIA_REVISE"] = "manual" # Try to make sure Revise isn't enabled.

    if ssi.depot_path == ""
        delete!(env_to_use, "JULIA_DEPOT_PATH")
    else
        env_to_use["JULIA_DEPOT_PATH"] = ssi.depot_path
    end

    stderr_for_client_process = VERSION < v"1.1.0" ? nothing : IOBuffer()

    if ssi.process !== nothing
        to_cancel_p = ssi.process
        ssi.process = nothing
        push!(ssi.canceled_processes, to_cancel_p)
        kill(to_cancel_p)
    end

    use_code_coverage = Base.JLOptions().code_coverage

    currently_loading_a_package = false
    current_package_name = ""

    pipename = pipe_name()

    server_is_ready = Channel(1)
    @async try
        server = Sockets.listen(pipename)

        put!(server_is_ready, nothing)
        conn = Sockets.accept(server)

        while isopen(conn)
            s = readline(conn)
            if isempty(s)
                continue
            end
            parts = split(s, ';')
            if parts[1] == "STARTLOAD"
                currently_loading_a_package = true
                current_package_name = parts[2]
                current_package_uuid = parts[3]
                current_package_version = parts[4]
                percentage = parts[5] == "missing" ? missing : parse(Int, parts[5])
                progress_callback !== nothing && progress_callback("Indexing $current_package_name...", percentage)
            elseif parts[1] == "STOPLOAD"
                currently_loading_a_package = false
            elseif parts[1] == "PROCESSPKG"
                current_package_name = parts[2]
                percentage = parts[5] == "missing" ? missing : parse(Int, parts[5])
                progress_callback !== nothing && progress_callback("Processing $current_package_name...", percentage)
            elseif parts[1] == "DONE"
                break
            else
                error("Unknown command.")
            end
        end
    catch err
        bt = catch_backtrace()
        if error_handler !== nothing
            error_handler(err, bt)
        else
            Base.display_error(stderr, err, bt)
        end
    end
    take!(server_is_ready)
    p = open(pipeline(Cmd(`$jl_cmd --code-coverage=$(use_code_coverage==0 ? "none" : "user") --startup-file=no --compiled-modules=no --history-file=no --project=$environment_path $server_script $(ssi.store_path) $pipename`, env=env_to_use),  stderr=stderr_for_client_process), read=true, write=true)
    ssi.process = p

    yield()

    if success(p)
        # Now we create a new symbol store and load everything into that
        # from disk
        new_store = recursive_copy(stdlibs)
        load_project_packages_into_store!(ssi, environment_path, new_store, progress_callback)
        @debug "SymbolStore: store success"
        return :success, new_store
    elseif p in ssi.canceled_processes
        delete!(ssi.canceled_processes, p)
        @debug "SymbolStore: store canceled"
        return :canceled, nothing
    else
        @debug "SymbolStore: store failure"
        if currently_loading_a_package
            return :package_load_crash, (package_name = current_package_name, stderr = stderr_for_client_process)
        else
            return :failure, stderr_for_client_process
        end
    end
end

function pipe_name()
    if Sys.iswindows()
        return "\\\\.\\pipe\\vscjlsymserv-$(UUIDs.uuid4())"
    end
    # Pipe names on unix may only be 92 chars (JuliaLang/julia#43281), and since
    # tempdir can be arbitrary long (in particular on macos) we try to keep the name
    # within bounds here.
    prefix = "vscjlsymserv-"
    uuid = string(UUIDs.uuid4())
    pipename = joinpath(tempdir(), prefix * uuid[1:13])
    if length(pipename) >= 92
        # Try to use /tmp and if that fails, hope the long pipe name works anyway
        maybe = "/tmp/" * prefix * uuid
        try
            touch(maybe); rm(maybe) # Check permissions on this path
            pipename = maybe
        catch
        end
    end
    return pipename
end

function load_project_packages_into_store!(ssi::SymbolServerInstance, environment_path, store, progress_callback = nothing)
    project_filename = isfile(joinpath(environment_path, "JuliaProject.toml")) ? joinpath(environment_path, "JuliaProject.toml") : joinpath(environment_path, "Project.toml")
    project = try
        Pkg.API.read_project(project_filename)
    catch err
        @warn "Could not load project."
        return
    end

    manifest_filename = isfile(joinpath(environment_path, "JuliaManifest.toml")) ? joinpath(environment_path, "JuliaManifest.toml") : joinpath(environment_path, "Manifest.toml")
    manifest = read_manifest(manifest_filename)
    manifest === nothing && return
    uuids = values(deps(project))
    num_uuids = length(values(deps(project)))
    for (i, uuid) in enumerate(uuids)
        load_package_from_cache_into_store!(ssi, uuid isa UUID ? uuid : UUID(uuid), environment_path, manifest, store, progress_callback, round(Int, 100 * (i - 1) / num_uuids))
    end
end

"""
    load_package_from_cache_into_store!(ssp::SymbolServerInstance, uuid, store)

Tries to load the on-disk stored cache for a package (uuid). Attempts to generate (and save to disk) a new cache if the file does not exist or is unopenable.
"""
function load_package_from_cache_into_store!(ssi::SymbolServerInstance, uuid::UUID, environment_path, manifest, store, progress_callback = nothing, percentage = missing)
    yield()
    isinmanifest(manifest, uuid) || return
    pe = frommanifest(manifest, uuid)
    pe_name = packagename(manifest, uuid)
    haskey(store, Symbol(pe_name)) && return


    # further existence checks needed?
    cache_path = joinpath(ssi.store_path, get_cache_path(manifest, uuid)...)
    if isfile(cache_path)
        progress_callback !== nothing && progress_callback("Loading $pe_name from cache...", percentage)
        try
            package_data = open(cache_path) do io
                CacheStore.read(io)
            end

            pkg_path = Base.locate_package(Base.PkgId(uuid, pe_name))
            if pkg_path === nothing || !isfile(pkg_path)
                pkg_path = get_pkg_path(Base.PkgId(uuid, pe_name), environment_path, ssi.depot_path)
            end
            if pkg_path !== nothing
                modify_dirs(package_data.val, f -> modify_dir(f, r"^PLACEHOLDER", joinpath(pkg_path, "src")))
            end

            store[Symbol(pe_name)] = package_data.val
            for dep in deps(pe)
                load_package_from_cache_into_store!(ssi, packageuuid(dep), environment_path, manifest, store, progress_callback, percentage)
            end
        catch err
            Base.display_error(stderr, err, catch_backtrace())
            @warn "Tried to load $pe_name but failed to load from disk, re-caching."
            try
                rm(cache_path)
            catch err2
                # There could have been a race condition that the file has been deleted in the meantime,
                # we don't want to crash then.
                err2 isa Base.IOError || rethrow(err2)
            end
        end
    else
        @warn "$(pe_name) not stored on disk"
        store[Symbol(pe_name)] = ModuleStore(VarRef(nothing, Symbol(pe_name)), Dict{Symbol,Any}(), "$pe_name failed to load.", true, Symbol[], Symbol[])
    end
end

function clear_disk_store(ssi::SymbolServerInstance)
    for f in readdir(ssi.store_path)
        if occursin(f, "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            rm(joinpath(ssi.store_path, f), recursive = true)
        end
    end
end

function index_package(
    name::Symbol,
    version::VersionNumber,
    uuid::UUID,
    treehash::String,
    store_path::String,
    m::Module
)
    @time begin
        # Get the symbols
        env = @time getenvtree([name])
        @time symbols(env, m, get_return_type=true)

        # Strip out paths
        @time begin
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

        @time begin
            filename_with_extension = "v$(replace(string(version), '+'=>'_'))_$treehash.jstore"
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

# Method to check whether a package is part of the standard library and so
# won't need recaching.
function is_stdlib(uuid::UUID)
    if isdefined(Pkg.Types, :is_stdlib)
        return Pkg.Types.is_stdlib(uuid)
    else
        return uuid in keys(ctx.stdlibs)
    end
end

function index_packages(conn, store_path::String, loadingbay)
    start_time = time_ns()

    ctx = try
        Pkg.Types.Context()
    catch err
        @info "Package environment can't be read."
        exit()
    end

    server = Server(store_path, ctx, Dict{UUID,Package}())

    written_caches = String[] # List of caches that have already been written
    toplevel_pkgs = deps(project(ctx)) # First get a list of all package UUIds that we want to cache
    packages_to_load = []

    # Next make sure the cache is up-to-date for all of these
    for (pk_name, uuid) in toplevel_pkgs
        uuid isa UUID || (uuid = UUID(uuid))
        if !isinmanifest(ctx, uuid)
            @info "$pk_name not in manifest, skipping."
            continue
        end
        pe = frommanifest(manifest(ctx), uuid)
        cache_path = joinpath(server.storedir, SymbolServer.get_cache_path(manifest(ctx), uuid)...)

        if isfile(cache_path)
            if is_package_deved(manifest(ctx), uuid)
                try
                    cached_version = open(cache_path) do io
                        CacheStore.read(io)
                    end
                    if sha_pkg(frommanifest(manifest(ctx), uuid)) != cached_version.sha
                        @info "Outdated sha, will recache package $pk_name ($uuid)"
                        push!(packages_to_load, uuid)
                    else
                        @info "Package $pk_name ($uuid) is cached."
                    end
                catch err
                    @info "Couldn't load $pk_name ($uuid) from file, will recache."
                end
            else
                @info "Package $pk_name ($uuid) is cached."
            end
        else
            @info "Will cache package $pk_name ($uuid)"
            push!(packages_to_load, uuid)
        end
    end

    visited = Base.IdSet{Module}([Base, Core])

    # Load all packages together
    for (i, uuid) in enumerate(packages_to_load)
        @info "Loading: $uuid"
        load_package(ctx, uuid, conn, loadingbay, round(Int, 100*(i - 1)/length(packages_to_load)))
    end

    # This used to run all of the following *inside* the loop over package_to_load above.
    # This duplicated a lot of work; moving it outside the loop made the time go from 109.1 seconds to 12.2 seconds
    # for indexing an environment with only "Plots".
    # The old method, while inefficient, allowed SymbolServer to write its work periodically, so some symbol cache files
    # could be written even if the symbol server was killed while working.
    # To get the best of both worlds, it would be best to refactor to actually process package-by-package, rather
    # than operating globally with getenvtree(), getallns(), etc.

    # Create image of whole package env. This creates the module structure only.
    env_symbols = getenvtree()

    # Populate the above with symbols, skipping modules that don't need caching.
    for (pid, m) in Base.loaded_modules
        if pid.uuid !== nothing &&
            is_stdlib(pid.uuid) &&
            isinmanifest(ctx, pid.uuid) &&
            isfile(joinpath(server.storedir, SymbolServer.get_cache_path(manifest(ctx), pid.uuid)...))
            push!(visited, m)
            delete!(env_symbols, Symbol(pid.name))
        end
    end

    symbols(env_symbols, nothing, getallns(), visited)

    # Wrap the `ModuleStore`s as `Package`s.
    for (pkg_name, cache) in env_symbols
        !isinmanifest(ctx, String(pkg_name)) && continue
        uuid = packageuuid(ctx, String(pkg_name))
        pe = frommanifest(ctx, uuid)
        server.depot[uuid] = Package(String(pkg_name), cache, uuid, sha_pkg(pe))
    end

    write_depot(server, server.context, written_caches)

    @info "Symbol server indexing took $((time_ns() - start_time) / 1e9) seconds."
end

if !haskey(ENV, "SKIP_LOAD_CORE")
    const stdlibs = load_core()
end

function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    Base.precompile(Tuple{Type{SymbolServer.DataTypeStore},SymbolServer.FakeTypeName,SymbolServer.FakeTypeName,Array{Any,1},Array{Any,1},Array{Symbol,1},Array{Any,1},String,Bool})
    Base.precompile(Tuple{typeof(SymbolServer.cache_methods),Any,Dict{Symbol,SymbolServer.ModuleStore}})
    Base.precompile(Tuple{typeof(SymbolServer.getenvtree)})
    Base.precompile(Tuple{typeof(SymbolServer.symbols),Dict{Symbol,SymbolServer.ModuleStore}})
    Base.precompile(Tuple{typeof(copy),Base.Broadcast.Broadcasted{Base.Broadcast.Style{Tuple},Nothing,typeof(SymbolServer._parameter),Tuple{NTuple{4,Symbol}}}})
end
VERSION >= v"1.4.2" && _precompile_()

end # module
