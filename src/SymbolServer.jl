module SymbolServer

export SymbolServerProcess
export getstore

using Serialization

mutable struct SymbolServerProcess
    process::Base.Process

    function SymbolServerProcess(;environment=nothing, depot=nothing)
        jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
        client_process_script = joinpath(@__DIR__, "clientprocess", "clientprocess_main.jl")

        env_to_use = copy(ENV)

        if depot!==nothing
            if depot==""
                delete!(env_to_use, "JULIA_DEPOT_PATH")
            else
                env_to_use["JULIA_DEPOT_PATH"] = depot
            end
        end

        p = if environment===nothing
            open(Cmd(`$jl_cmd $client_process_script`, env=env_to_use), read=true, write=true)
        else
            open(Cmd(`$jl_cmd --project=$environment $client_process_script`, dir=environment, env=env_to_use), read=true, write=true)
        end
    
        return new(p)
    end
end

function request(server::SymbolServerProcess, message::Symbol, payload)
    serialize(server.process, (message, payload))
    ret_val = deserialize(server.process)
    return ret_val
end

function save_store_to_disc(store, file)
    io = open(file, "w")
    serialize(io, store)
    close(io)
end

function load_store_from_disc(file)
    io = open(file)
    store = deserialize(io)
    close(io)
    for (m,v) in store
        if v isa Dict && haskey(v, ".exported")
            v[".exported"] = Set{String}(string.(v[".exported"]))
        end
    end
    return store
end

function collect_mods(store, mods = [], root = "")
    for (k,v) in store
        if v isa Dict && !startswith(first(v)[1], ".")
            push!(mods, join([root, k], ".")[2:end])
            collect_mods(v, mods, join([root, k], "."))
        end
    end
    mods
end

# Public API

function getstore(server::SymbolServerProcess)
    if !isfile(joinpath(@__DIR__, "..", "store", "base.jstore"))
        store = load_base(server)
        save_store_to_disc(store, joinpath(@__DIR__, "..", "store", "base.jstore"))
    else
        store = load_store_from_disc(joinpath(@__DIR__, "..", "store", "base.jstore"))
    end

    pkgs_in_env = get_packages_in_env(server)
    for pkg in pkgs_in_env
        pkg_name = pkg[1]
        if !isfile(joinpath(@__DIR__, "..", "store", "$pkg_name.jstore"))
            pstore = load_module(server, pkg)
            save_store_to_disc(pstore, joinpath(@__DIR__, "..", "store", "$pkg_name.jstore"))
        else
            pstore = load_store_from_disc(joinpath(@__DIR__, "..", "store", "$pkg_name.jstore"))            
        end
        store[string(pkg_name)] = pstore
    end

    store[".importable_mods"] = collect_mods(store)

    return store
end

function Base.kill(s::SymbolServerProcess)
    kill(s.process)
end

function get_packages_in_env(server::SymbolServerProcess)
    status, payload = request(server, :get_packages_in_env, nothing)
    if status == :success
        return payload
    else
        error(payload)
    end
end

function load_base(server::SymbolServerProcess)
    status, payload = request(server, :load_base, nothing)
    if status == :success
        return payload
    else
        error(payload)
    end
end


function load_module(server::SymbolServerProcess, pkg)
    status, payload = request(server, :load_module, pkg)
    if status == :success
        return payload
    else
        error(payload)
    end
end

end # module
