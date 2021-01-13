max_n = 1_000_000
max_tasks = 36

using Pkg, UUIDs

Pkg.activate(@__DIR__)
Pkg.instantiate()

using ProgressMeter

function get_all_package_versions()
    registry_folder_path = joinpath(homedir(), ".julia", "registries", "General")
    registry_path = joinpath(registry_folder_path, "Registry.toml")

    registry_content = Pkg.TOML.parsefile(registry_path)

    registry_content_packages = registry_content["packages"]

    packages = map(collect(keys(registry_content_packages))) do i
        foo = (name=registry_content_packages[i]["name"], uuid=UUID(i), path=registry_content_packages[i]["path"])

        versions_content = Pkg.TOML.parsefile(joinpath(registry_folder_path, foo.path, "Versions.toml"))

        foo = (foo..., versions=map(j->VersionNumber(j), collect(keys(versions_content))))
    end

    return packages
end

function get_flattened_package_versions(packages)
    flattened_packageversions = []

    for p in packages
        for v in p.versions
            push!(flattened_packageversions, (;p.name, p.uuid, p.path, version=v))
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

run(Cmd(`docker build . -t juliavscodesymbolindexer -f registryindexer/Dockerfile`, dir=joinpath(@__DIR__, "..")))

cache_folder = joinpath(@__DIR__, "..", "registryindexcache")

p = Progress(min(max_n, length(flattened_packageversions)), 1)

asyncmap(Iterators.take(flattened_packageversions, max_n), ntasks=max_tasks) do v
    res = execute(`docker run --rm --mount type=bind,source="$cache_folder",target=/symcache juliavscodesymbolindexer julia SymbolServer/src/indexpackage.jl $(v.name) $(v.version)`)

    versionwithoutplus = replace(string(v.version), '+'=>'_')

    open(joinpath(cache_folder, "log_$(v.name)_$(versionwithoutplus)_stdout.txt"), "w") do f
        print(f, res.stdout)
    end

    open(joinpath(cache_folder, "log_$(v.name)_$(versionwithoutplus)_stderr.txt"), "w") do f
        print(f, res.stderr)
    end

    next!(p, showvalues = [(:finished_package_count,p.counter)])
end

finish!(p)
