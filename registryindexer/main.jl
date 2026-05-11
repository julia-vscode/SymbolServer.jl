@info "Initializing indexing process..."

max_n = 5000
max_versions = 1_000_000
timeout_per_package = 60*20 # 20 minutes
max_tasks = length(ARGS)>1 ? parse(Int, ARGS[2]) : 1

julia_versions = [v"1.12.5"]

using Pkg

Pkg.activate(@__DIR__)
Pkg.instantiate()

using ProgressMeter, Query, UUIDs, Tar, CodecZlib, CancellationTokens

function get_all_package_versions(;max_versions=typemax(Int))
    registry_folder_path = joinpath(homedir(), ".julia", "registries", "General")
    registry_path = joinpath(registry_folder_path, "Registry.toml")

    registry_content = Pkg.TOML.parsefile(registry_path)

    packages = registry_content["packages"] |>
        @map({
            name = _[2]["name"],
            uuid = UUID(_[1]),
            path = _[2]["path"]
        }) |>
        @mutate(
            versions = (Pkg.TOML.parsefile(joinpath(registry_folder_path, _.path, "Versions.toml")) |>
                @map(i->{version=VersionNumber(i[1]), treehash=i[2]["git-tree-sha1"]}) |>
                @orderby_descending(i->i.version) |>
                @take(max_versions) |>
                collect)
        ) |>
        collect

    return packages
end

function get_flattened_package_versions(packages)
    flattened_packageversions = []

    for p in packages
        for v in p.versions
            push!(flattened_packageversions, (;p.name, p.uuid, p.path, version=v.version, treehash=v.treehash))
        end
    end

    return flattened_packageversions
end

function execute(cmd::Base.Cmd)
    out = IOBuffer()
    err = IOBuffer()
    process = run(pipeline(ignorestatus(cmd), stdout=out, stderr=err))

    out_string =String(take!(out))
    err_string = String(take!(err))
    return (stdout = out_string,
            stderr = err_string,
            code = process.exitcode)
end

@info "Indexing started..."

all_packages = get_all_package_versions(max_versions=max_versions)

flattened_packageversions = get_flattened_package_versions(all_packages)

@info "Loaded package versions from registry..."

cache_folder = length(ARGS)>0 ? ARGS[1] : joinpath(@__DIR__, "..", "registryindexcache")

@info "Using the following folder as the cache folder: " cache_folder

rm(joinpath(cache_folder, "logs"), force=true, recursive=true)
mkpath(joinpath(cache_folder, "logs"))
mkpath(joinpath(cache_folder, "logs", "packageloadfailure"))
mkpath(joinpath(cache_folder, "logs", "packageinstallfailure"))
mkpath(joinpath(cache_folder, "logs", "packageindexfailure"))

@info "Building docker image..."

asyncmap(julia_versions) do v
    res = execute(Cmd(`docker build . -t juliavscodesymbolindexer:$v --build-arg JULIA_VERSION=$v -f registryindexer/Dockerfile`, dir=joinpath(@__DIR__, "..")))

    open(joinpath(cache_folder, "logs", "docker_image_create_$(v)_stdout.txt"), "w") do f
        print(f, res.stdout)
    end

    open(joinpath(cache_folder, "logs", "docker_image_create_$(v)_stderr.txt"), "w") do f
        print(f, res.stderr)
    end

    if res.code!=0
        error("Could not create docker image.")
    end
end

@info "Done building docker images."


true || asyncmap(julia_versions) do v
    cache_path = joinpath(cache_folder, "v1", "julia", "v$v.tar.gz")

    if isfile(cache_path)
        # global count_already_cached += 1
    else
        res = execute(`docker run --rm --mount type=bind,source="$cache_folder",target=/symcache juliavscodesymbolindexer:$v julia SymbolServer/src/indexbasestdlib.jl $v`)

        if res.code==10 || res.code==20
            if res.code==10
                # global count_failed_to_load += 1
            elseif res.code==20
                # global count_failed_to_install += 1
            end

            # mktempdir() do path
            #     error_filename = "v$(versionwithoutplus)_$(v.treehash).unavailable"

            #     # Write them to a file
            #     open(joinpath(path, error_filename), "w") do io
            #     end

            #     Pkg.PlatformEngines.package(path, cache_path)
            # end

            # open(joinpath(cache_folder, "logs", res.code==10 ? "packageloadfailure" : "packageinstallfailure", "log_$(v.name)_v$(versionwithoutplus)_stdout.txt"), "w") do f
            #     print(f, res.stdout)
            # end

            # open(joinpath(cache_folder, "logs", res.code==10 ? "packageloadfailure" : "packageinstallfailure", "log_$(v.name)_v$(versionwithoutplus)_stderr.txt"), "w") do f
            #     print(f, res.stderr)
            # end

            # global status_db

            # push!(status_db, Dict("name"=>v.name, "uuid"=>string(v.uuid), "version"=>string(v.version), "treehash"=>v.treehash, "status"=>res.code==20 ? "install_error" : "load_error", "indexattempts"=>[Dict("juliaversion"=>string(VERSION), "stdout"=>res.stdout, "stderr"=>res.stderr)]))
        elseif res.code==0
            # global count_successfully_cached += 1
        else
            # global count_failed_to_index += 1
            # open(joinpath(cache_folder, "logs", "packageindexfailure", "log_$(v.name)_v$(versionwithoutplus)_stdout.txt"), "w") do f
            #     print(f, res.stdout)
            # end

            # open(joinpath(cache_folder, "logs", "packageindexfailure", "log_$(v.name)_v$(versionwithoutplus)_stderr.txt"), "w") do f
            #     print(f, res.stderr)
            # end
        end
    end
end

@info "Now computing which of the total $(length(flattened_packageversions)) package versions that exist still need to be indexed..."

unindexed_packageversions = Iterators.take(filter(flattened_packageversions) do v
    versionwithoutplus = replace(string(v.version), '+'=>'_')

    cache_path = joinpath(cache_folder, "v2", "packages", string(uppercase(v.name[1])), v.name, string(v.uuid), "$(v.treehash).tar.gz")

    return !isfile(cache_path)
end, max_n)

p = Progress(min(max_n, length(unindexed_packageversions)), 1)

count_failed_to_load = 0
count_failed_to_index = 0
count_failed_to_install = 0
count_timeout = 0
count_successfully_cached = 0

@info "There are $(length(unindexed_packageversions)) new package/version combinations that need to be indexed. We will index at most $max_n."

@info "Starting the actual indexing process..."

asyncmap(unindexed_packageversions, ntasks=max_tasks) do v
    versionwithoutplus = replace(string(v.version), '+'=>'_')

    cache_path = joinpath(cache_folder, "v2", "packages", string(uppercase(v.name[1])), v.name, string(v.uuid))
    mkpath(cache_path)
    cache_path_compressed = joinpath(cache_path, "$(v.treehash).tar.gz")

    mktempdir() do path
        cancel_source = CancellationTokenSource(timeout_per_package)

        token = get_token(cancel_source)

        container_name = "Julia_indexing_$(uuid4())"

        res = execute(`docker run --rm -d --name $container_name --mount type=bind,source="$path",target=/symcache juliavscodesymbolindexer:$(first(julia_versions)) julia --startup-file=no --compiled-modules=existing --history-file=no SymbolServer/src/indexpackage.jl $(v.name) $(v.version) $(v.uuid) $(v.treehash)`)

        register(token) do
            execute(`docker stop $container_name`)
        end

        res = execute(`docker wait $container_name`)

        exit_code = tryparse(Int, res.stdout)

        # @info "THE EXIT CODE IS" exit_code

        if exit_code==37 # This is our magic error code that indicates everything worked
            global count_successfully_cached += 1
        else
            if is_cancellation_requested(token)
                global count_timeout += 1
            elseif exit_code==10
                global count_failed_to_load += 1
            elseif exit_code==20
                global count_failed_to_install += 1
            else
                global count_failed_to_index += 1
            end

            # @info res.code

            # @info res.stdout
            # @info res.stderr

            error_filename = "$(v.treehash).unavailable"

            isfile(joinpath(path, error_filename)) && rm(joinpath(path, error_filename))

            # Write them to a file
            open(joinpath(path, error_filename), "w") do io
            end

            open(joinpath(cache_folder, "logs", res.code==10 ? "packageloadfailure" : res.code==20 ? "packageinstallfailure" : "packageindexfailure", "log_$(v.name)_v$(versionwithoutplus)_stdout.txt"), "w") do f
                print(f, res.stdout)
            end

            open(joinpath(cache_folder, "logs", res.code==10 ? "packageloadfailure" : res.code==20 ? "packageinstallfailure" : "packageindexfailure", "log_$(v.name)_v$(versionwithoutplus)_stderr.txt"), "w") do f
                print(f, res.stderr)
            end
        end

        # @info "Files to be compressed" path readdir(path, join=true) ispath(cache_path) isfile(cache_path_compressed)

        open(cache_path_compressed, write=true) do tar_gz
            tar = GzipCompressorStream(tar_gz)
            try
                Tar.create(path, tar)
            finally
                close(tar)
            end
        end
    end

    next!(p, showvalues = [
        (:finished_package_count,p.counter+1),
        (:count_successfully_cached, count_successfully_cached),
        (:count_failed_to_install, count_failed_to_install),
        (:count_failed_to_load, count_failed_to_load),
        (:count_failed_to_index, count_failed_to_index),
        (:count_timeout, count_timeout),
    ])
end

@info "Indexing finished."
