module SymbolServer

using Serialization, Pkg, SHA
include("from_static_lint.jl")

const storedir = abspath(joinpath(@__DIR__, "..", "..", "store"))
const c = Pkg.Types.Context()
const depot = create_depot(c, Dict{String,Any}())

if Sys.isunix()
    global const nullfile = "/dev/null"
elseif Sys.iswindows()
    global const nullfile = "nul"
else
    error("Platform not supported")
end

while true
    message, payload = deserialize(stdin)
    empty!(depot["packages"])
    try
        if message == :debugmessage
            @info(payload)
            serialize(stdout, (:success, nothing))
        elseif message == :close
            break
        elseif message == :get_context
            serialize(stdout, (:success, c))
        elseif message == :get_core_packages
            core_pkgs = load_core()["packages"]
            SymbolServer.save_store_to_disc(core_pkgs["Base"], joinpath(storedir, "Base.jstore"))
            SymbolServer.save_store_to_disc(core_pkgs["Core"], joinpath(storedir, "Core.jstore"))
            serialize(stdout, (:success, nothing))
        elseif message == :load_package
            open(nullfile, "w") do f
                redirect_stdout(f) do # seems necessary incase packages print on startup
                    SymbolServer.import_package(payload, depot)
                end
            end
            for  (uuid, pkg) in depot["packages"]
                SymbolServer.save_store_to_disc(pkg, joinpath(storedir, "$uuid.jstore"))
            end
            serialize(stdout, (:success, [k=>v.name for (k,v) in depot["packages"] if v.name isa String]))
        elseif message == :load_all
            for pkg in (VERSION < v"1.1.0-DEV.857" ? c.env.project["deps"] : c.env.project.deps)
                SymbolServer.import_package(c.env.manifest[last(pkg)], depot)
            end
            for (uuid, pkg) in depot["packages"]
                SymbolServer.save_store_to_disc(pkg, joinpath(storedir, "$uuid.jstore"))
            end
            serialize(stdout, (:success, [k=>v.name for (k,v) in depot["packages"] if v.name isa String]))
        else
            serialize(stdout, (:failure, nothing))
        end
    catch err
        serialize(stdout, (:failure, err))
    end
end

end
