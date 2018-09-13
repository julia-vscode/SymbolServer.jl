using Serialization, Pkg

include("from_static_lint.jl")

while true
    message, payload = deserialize(stdin)

    try
        if message == :debugmessage
            @info(payload)
            serialize(stdout, (:success, nothing))
        elseif message == :get_packages_in_env
            pkgs = collect(Symbol.(keys(Pkg.API.installed())))

            serialize(stdout, (:success, pkgs))
        elseif message == :get_module_doc
            docs = string(Docs.doc(getfield(Main, payload)))

            serialize(stdout, (:success, docs))
        elseif message == :get_doc
            docs = string(Docs.doc(getfield(Main, payload.mod), payload.name))

            serialize(stdout, (:success, docs))
        elseif message == :import
            @eval import $payload

            mod_names = read_module(getfield(Main, payload))
            serialize(stdout, (:success, mod_names))
        end
    catch err
        serialize(stdout, (:failure, err))
    end
end