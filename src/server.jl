module SymbolServer

conn = stdout
(outRead, outWrite) = redirect_stdout()

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
        serialize(conn, (:success, server.context))
    elseif message == :cache_package
        for uuid in payload
            cache_package(server.context, UUID(uuid), server.depot)
        end
        out = Tuple{String,String,Bool,Bool,Bool}[] # list of saved caches
        for  (uuid, pkg) in server.depot
            overwrote = isfile(joinpath(server.storedir, "$(string(uuid)).jstore"))
            write_cache(uuid, pkg)

            isloaded = can_access(LoadingBay, Symbol(packagename(server.context, uuid))) isa Module
            issaved = isfile(joinpath(server.storedir, "$(string(uuid)).jstore"))

            push!(out, (string(uuid), packagename(server.context, uuid), isloaded, isloaded, overwrote))
        end
        serialize(conn, (:success, out))
    elseif message == :change_env
        Pkg.API.activate(payload)
        server.context = Pkg.Types.Context()
        serialize(conn, (:success, nothing))
    elseif message == :debugmessage
        out = string(eval(Meta.parse(payload)))
        serialize(conn, (:success, out))
    elseif message == :close
        break
    else
        serialize(conn, (:failure, nothing))
    end
end
end
