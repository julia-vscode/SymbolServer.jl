using Serialization, Pkg

module SymbolServer

    using Serialization, Pkg
    include("from_static_lint.jl")
    
end

global our_import = (name) -> Main.eval(:(import $(Symbol(name))))
global our_installedpackages = () -> Pkg.Types.Context().env.project["deps"]

# If the project is part of the current environment, do this
if length(ARGS)>0
    pkgname = basename(ARGS[1])

    # Is this package part of the current environment?
    if haskey(Pkg.Types.Context().env.manifest, pkgname) && Pkg.Types.Context().env.manifest[pkgname][1]["path"] == ARGS[1]
        ctx = Pkg.Types.Context()
        pkg = PackageSpec(pkgname)

        Pkg.API.project_resolve!(ctx.env, [pkg])
        Pkg.API.project_deps_resolve!(ctx.env, [pkg])
        Pkg.API.manifest_resolve!(ctx.env, [pkg])
        Pkg.API.ensure_resolved(ctx.env, [pkg])

        global our_import = (name) -> begin
            Pkg.Operations.with_dependencies_loadable_at_toplevel(ctx, pkg) do localctx
                Pkg.API.activate(dirname(localctx.env.project_file))
                Main.eval(:(import $(Symbol(name))))
            end
        end

        global our_installedpackages = () -> begin
            ret = nothing
            Pkg.Operations.with_dependencies_loadable_at_toplevel(ctx, pkg) do localctx
                Pkg.API.activate(dirname(localctx.env.project_file))
                ret = Pkg.Types.Context().env.project["deps"]                
            end
            return ret
        end
    end
end

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
            pkgs = our_installedpackages()
            @info pkgs
            serialize(stdout, (:success, pkgs))
        elseif message == :load_package
            ostdout = stdout
            (outRead, outWrite) = redirect_stdout() # seems necessary incase packages print on startup

            @info "Trying to import $payload"
            our_import(payload[1])
            @info "DONE LOADING"

            SymbolServer.import_package(payload, depot)

            @info "IMPORT WORKED"

            for  (uuid, pkg) in depot["packages"]
                SymbolServer.save_store_to_disc(pkg, joinpath(storedir, "$uuid.jstore"))
            end
            @info "SAVE WORKED"
            close(outWrite) 
            close(outRead)
            redirect_stdout(ostdout)
            serialize(stdout, (:success, collect(keys(depot["packages"]))))
        else
            serialize(stdout, (:failure, nothing))
        end
    catch err
        serialize(stdout, (:failure, err))
    end
end