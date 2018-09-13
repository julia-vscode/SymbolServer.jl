module SymbolServer

export SymbolServerProcess
export get_packages_in_env, get_doc, import_module

using Serialization

mutable struct SymbolServerProcess
    process::Base.Process

    function SymbolServerProcess(environment=nothing)
        jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
        client_process_script = joinpath(@__DIR__, "clientprocess", "clientprocess_main.jl")
        
        p = if environment===nothing
            open(Cmd(`$jl_cmd $client_process_script`), read=true, write=true)
        else
            open(Cmd(`$jl_cmd --project=$environment $client_process_script`, dir=environment), read=true, write=true)
        end
    
        return new(p)
    end
end

function request(server::SymbolServerProcess, message::Symbol, payload)
    serialize(server.process, (message, payload))
    ret_val = deserialize(server.process)
    return ret_val
end

# Public API

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

function get_doc(server::SymbolServerProcess, mod::Symbol)
    status, payload = request(server, :get_module_doc, mod)
    if status == :success
        return payload
    else
        error(payload)
    end
end

function get_doc(server::SymbolServerProcess, mod::Symbol, name::Symbol)
    status, payload = request(server, :get_doc, (mod=mod, name=name))
    if status == :success
        return payload
    else
        error(payload)
    end
end

function import_module(server::SymbolServerProcess, name::Symbol)
    status, payload = request(server, :import, name)
    if status == :success
        return payload
    else
        error(payload)
    end
end

end # module
