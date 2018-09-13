function read_methods(x)
    map(methods(x)) do m
        Dict("type" => "method",
             "file" => String(m.file),
             "line" => m.line,
             "args" => Base.arg_decl_parts(m)[2][2:end])
    end
end

function collect_params(t, params = [])
    if t isa UnionAll
        push!(params, t.var)
        return collect_params(t.body, params)
    else
        return t, params
    end
end

function read_module(m)
    out = Dict()
    out[".type"] = "module"
    out[".exported"] = names(m)
    for n in names(m, all = true)
        !isdefined(m, n) && continue
        startswith(string(n), "#") && continue
        if false #Base.isdeprecated(m, n)
        else
            x = getfield(m, n)
            if x isa Function
                out[String(n)] = Dict(
                    ".type" => "Function",
                    ".methods" => read_methods(x))
            elseif x isa DataType
                t, p = collect_params(x)
                if t.abstract
                    out[String(n)] = Dict(
                        ".type" => "abstract",
                        ".params" => string.(p))
                elseif t.isbitstype
                    out[String(n)] = Dict(
                        ".type" => "primitive",
                        ".params" => string.(p))
                elseif !(isempty(t.types) || Base.isvatuple(t))
                    out[String(n)] = Dict(
                        ".type" => "struct",
                        ".params" => string.(p),
                        ".fields" => collect(string.(fieldnames(t))),
                        ".types" => string.(collect(t.types)),
                        ".methods" => read_methods(x))
                else
                    out[String(n)] = Dict(
                        ".type" => "DataType",
                        ".params" => string.(p))
                end
            elseif x isa Module && x != m
                if parentmodule(x) == m
                    out[string(n)] = read_module(x)
                end
            else
                out[String(n)] = Dict(
                    ".type" => string(typeof(x)))
            end
        end
    end
    out
end
