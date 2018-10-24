module SymbolServer
using Serialization, Pkg
include("from_static_lint.jl")
end

using Serialization, Pkg
const storedir = abspath(joinpath(@__DIR__, "..", "..", "store"))
const c = Pkg.Types.Context()
const depot = Dict("manifest" => c.env.manifest, 
                    "installed" => c.env.project["deps"],
                    "packages" => Dict{String,Any}())
while true
    message, payload = deserialize(stdin)

    try
        if message == :debugmessage
            @info(payload)
            serialize(stdout, (:success, nothing))
        elseif message == :get_installed_packages_in_env
            pkgs = c.env.project["deps"]
            serialize(stdout, (:success, pkgs))
        elseif message == :get_all_packages_in_env
            pkgs = Dict{String,Vector{String}}(n=>(p->get(p, "uuid", "")).(v) for (n,v) in c.env.manifest)
            serialize(stdout, (:success, pkgs))
        elseif message == :load_package
            ostdout = stdout
            (outRead, outWrite) = redirect_stdout() # seems necessary incase packages print on startup
            SymbolServer.import_package(payload, depot)
            for  (uuid, pkg) in depot["packages"]
                SymbolServer.save_store_to_disc(pkg, joinpath(storedir, "$uuid.jstore"))
            end
            close(outWrite) 
            close(outRead)
            redirect_stdout(ostdout)
            serialize(stdout, (:success, collect(keys(depot["packages"]))))
        elseif message == :load_all
            for pkg in c.env.project["deps"]
                SymbolServer.import_package(pkg, depot)
            end
            for  (uuid, pkg) in depot["packages"]
                SymbolServer.save_store_to_disc(pkg, joinpath(storedir, "$uuid.jstore"))
            end
            serialize(stdout, (:success, collect(keys(depot["packages"]))))
        else
            serialize(stdout, (:failure, nothing))
        end
    catch err
        serialize(stdout, (:failure, err))
    end
end