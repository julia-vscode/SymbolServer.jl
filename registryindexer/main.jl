max_n = 1_000_000
max_tasks = 36

using Pkg, UUIDs

Pkg.activate(@__DIR__)
Pkg.instantiate()

using ProgressMeter, Query

function get_all_package_versions()
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
            versions = Pkg.TOML.parsefile(joinpath(registry_folder_path, _.path, "Versions.toml")) |> @map(i->{version=VersionNumber(i[1]), treehash=i[2]["git-tree-sha1"]}) |> collect
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
    return (stdout = String(take!(out)),
            stderr = String(take!(err)),
            code = process.exitcode)
end

all_packages = get_all_package_versions()

flattened_packageversions = get_flattened_package_versions(all_packages)

cache_folder = length(ARGS)>0 ? ARGS[1] : joinpath(@__DIR__, "..", "registryindexcache")

mkpath(joinpath(cache_folder, "logs"))

@info "Building docker image..."

res = execute(Cmd(`docker build . -t juliavscodesymbolindexer -f registryindexer/Dockerfile`, dir=joinpath(@__DIR__, "..")))

open(joinpath(cache_folder, "logs", "docker_image_create_stdout.txt"), "w") do f
    print(f, res.stdout)
end

open(joinpath(cache_folder, "logs", "docker_image_create_stderr.txt"), "w") do f
    print(f, res.stderr)
end

if res.code!=0
    error("Could not create docker image.")
end

@info "Done building docker image."

p = Progress(min(max_n, length(flattened_packageversions)), 1)

count_failed_to_load = 0
count_already_cached = 0
count_successfully_cached = 0

@info "There are $(length(flattened_packageversions)) package/version combinations that need to be indexed. We will index at most $max_n."

asyncmap(Iterators.take(flattened_packageversions, max_n), ntasks=max_tasks) do v
    versionwithoutplus = replace(string(v.version), '+'=>'_')

    cache_path = joinpath(cache_folder, "v1", "packages", "$(v.name)_$(v.uuid)", "v$(versionwithoutplus)_$(v.treehash).jstore")

    if isfile(cache_path)
        global count_already_cached += 1
    else
        res = execute(`docker run --rm --mount type=bind,source="$cache_folder",target=/symcache juliavscodesymbolindexer julia SymbolServer/src/indexpackage.jl $(v.name) $(v.version) $(v.treehash)`)

        open(joinpath(cache_folder, "logs", "log_$(v.name)_$(versionwithoutplus)_stdout.txt"), "w") do f
            print(f, res.stdout)
        end

        open(joinpath(cache_folder, "logs", "log_$(v.name)_$(versionwithoutplus)_stderr.txt"), "w") do f
            print(f, res.stderr)
        end

        if res.code==-10
            global count_failed_to_load += 1
            open(joinpath(cache_folder, "v1", "packages", "$(v.name)_$(v.uuid)", "v$(versionwithoutplus)_$(v.treehash).failed.txt"), "w") do f
                print(f, "Could not load the package.")
            end
        else
            global count_successfully_cached += 1
        end
    end

    next!(p, showvalues = [(:finished_package_count,p.counter+1), (:count_failed_to_load, count_failed_to_load), (:count_already_cached, count_already_cached), (:count_successfully_cached, count_successfully_cached)])
end

