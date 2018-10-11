using Serialization, Pkg

include("from_static_lint.jl")

while true
    message, payload = deserialize(stdin)

    try
        if message == :debugmessage
            @info(payload)
            serialize(stdout, (:success, nothing))
        elseif message == :get_packages_in_env
            pkgs = Pkg.API.installed()

            serialize(stdout, (:success, pkgs))
        elseif message == :load_base
            bstore = load_base()
            serialize(stdout, (:success, bstore))
        elseif message == :load_module
            mstore = load_package(payload[1], Dict{String,Any}(), payload[2])
            serialize(stdout, (:success, mstore))
        end
    catch err
        serialize(stdout, (:failure, err))
    end
end