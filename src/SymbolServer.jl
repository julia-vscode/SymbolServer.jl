module SymbolServer

export SymbolServerProcess
export getstore

using Serialization, Pkg

include("clientprocess/from_static_lint.jl")

mutable struct SymbolServerProcess
    process::Base.Process

    function SymbolServerProcess(;environment=nothing, depot=nothing, project=nothing)
        jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
        client_process_script = joinpath(@__DIR__, "clientprocess", "clientprocess_main.jl")

        if depot==""
            depot = nothing
        end

        if environment==""
            environment = nothing
        end

        p = nothing

        withenv("JULIA_DEPOT_PATH"=>depot, "JULIA_PROJECT"=>environment, "JULIA_LOADPATH"=>nothing) do
            p = open(`$jl_cmd $client_process_script $project`, read=true, write=true)
        end
    
        return new(p)
    end
end

function request(server::SymbolServerProcess, message::Symbol, payload)
    serialize(server.process, (message, payload))
    ret_val = deserialize(server.process)
    return ret_val
end

function load_store_from_disc(file)
    io = open(file)
    store = deserialize(io)
    close(io)
    return store
end

# Public API

function getstore(server::SymbolServerProcess)
    depot = deepcopy(corepackages)
    storedir = abspath(joinpath(@__DIR__, "..", "store"))
    installed_pkgs_in_env = get_installed_packages_in_env(server)

    for (pkg_name, uuid) in installed_pkgs_in_env
        if isfile(joinpath(storedir, "$uuid.jstore"))
            depot[pkg_name] = load_store_from_disc(joinpath(storedir, "$uuid.jstore"))
        else
            load_package(server, pkg_name => uuid)
            if isfile(joinpath(storedir, "$uuid.jstore"))
                depot[pkg_name] = load_store_from_disc(joinpath(storedir, "$uuid.jstore"))
            end
        end
    end
    
    return depot
end

function Base.kill(s::SymbolServerProcess)
    kill(s.process)
end

function get_installed_packages_in_env(server::SymbolServerProcess)
    status, payload = request(server, :get_installed_packages_in_env, nothing)
    if status == :success
        return payload
    else
        error(payload)
    end
end

function load_package(server::SymbolServerProcess, pkg)
    status, payload = request(server, :load_package, pkg)
    if status == :success
        return payload
    else
        error(payload)
    end
end

const corepackages = load_core()["packages"]

end # module
