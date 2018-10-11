function read_methods(x)
    map(methods(x)) do m
        Dict("type" => "method",
             "file" => isabspath(String(m.file)) ? String(m.file) : Base.find_source_file(String(m.file)),
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
    out = Dict{String,Any}()
    out[".type"] = "module"
    out[".doc"] = string(Docs.doc(m))
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
                    ".methods" => read_methods(x),
                    ".doc" => string(Docs.doc(x)))
            elseif x isa DataType
                t, p = collect_params(x)
                if t.abstract
                    out[String(n)] = Dict(
                        ".type" => "abstract",
                        ".params" => string.(p),
                        ".doc" => string(Docs.doc(x)))
                elseif t.isbitstype
                    out[String(n)] = Dict(
                        ".type" => "primitive",
                        ".params" => string.(p),
                        ".doc" => string(Docs.doc(x)))
                elseif !(isempty(t.types) || Base.isvatuple(t))
                    out[String(n)] = Dict(
                        ".type" => "struct",
                        ".params" => string.(p),
                        ".fields" => collect(string.(fieldnames(t))),
                        ".types" => string.(collect(t.types)),
                        ".methods" => read_methods(x),
                        ".doc" => string(Docs.doc(x)))
                else
                    out[String(n)] = Dict(
                        ".type" => "DataType",
                        ".params" => string.(p),                        
                        ".doc" => string(Docs.doc(x)))
                end
            elseif x isa Module && x != m
                if parentmodule(x) == m
                    out[string(n)] = read_module(x)
                end
            else
                out[String(n)] = Dict(
                    ".type" => string(typeof(x)),
                    ".doc" => string(Docs.doc(x)))
            end
        end
    end
    return out
end

function load_module(M, store, v)
    store[string(M)] = read_module(M)
    if v != nothing
        store[string(M)]["package ver"] = string(v)
    end
end

function load_package(m, store, v)
    try
        Main.eval(:(import $(Symbol(m))))
        M = getfield(Main, Symbol(m))
        load_module(M, store, v)
    catch err
        show(err)
    end
end

function load_base()
    store = Dict{String,Any}()
    load_module(Base, store, nothing)
    push!(store["Base"][".exported"], :include)
    load_module(Core, store, nothing)
    c = Pkg.Types.Context()
    for (uuid,m) in c.stdlibs
        load_package(m, store, nothing)
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

