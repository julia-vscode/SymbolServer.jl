module SymbolServer
module LoadingBay
end
using Serialization, Pkg, SHA
using Base: UUID
@static if VERSION < v"1.1"
    const PackageEntry = Vector{Dict{String,Any}}
else
    using Pkg.Types: PackageEntry
end
include("symbols.jl")
include("utils.jl")

server = Server(abspath(joinpath(@__DIR__, "..", "store")), Pkg.Types.Context(), Dict{Any,Any}())
if Sys.isunix()
    global const nullfile = "/dev/null"
elseif Sys.iswindows()
    global const nullfile = "nul"
else
    error("Platform not supported")
end

function write_cache(uuid, pkg)
    open(joinpath(server.storedir, "$uuid.jstore"), "w") do io
        serialize(io, pkg)
    end
end

while true
    message, payload = deserialize(stdin)
    if message == :get_context
        serialize(stdout, (:success, server.context))
    elseif message == :cache_package
        for uuid in payload
            open(nullfile, "w") do f
                redirect_stdout(f) do # seems necessary incase packages print on startup
                    cache_package(server.context, UUID(uuid), server.depot)
                end
            end
        end
        out = String[] # list of saved caches
        for  (uuid, pkg) in server.depot
            write_cache(uuid, pkg)
            push!(out, string(uuid))
        end
        serialize(stdout, (:success, out))
    elseif message == :change_env
        open(nullfile, "w") do f
            redirect_stdout(f) do # seems necessary incase packages print on startup
                Pkg.API.activate(payload)
            end
        end
        server.context = Pkg.Types.Context()
        serialize(stdout, (:success, nothing))
    elseif message == :debugmessage
        out = string(eval(Meta.parse(payload)))
        serialize(stdout, (:success, out))
    elseif message == :close
        break
    else
        serialize(stdout, (:failure, nothing))
    end
end
end
