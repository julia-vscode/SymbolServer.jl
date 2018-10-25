abstract type SymStore end

struct MethodStore <: SymStore
    file::String
    line::Int
    args::Vector{Tuple{String,String}}
end

struct FunctionStore <: SymStore
    methods::Vector{MethodStore}
    doc::String
end

struct abstractStore <: SymStore
    params::Vector{String}
    doc::String
end

struct primitiveStore <: SymStore
    params::Vector{String}
    doc::String
end

struct structStore <: SymStore
    params::Vector{String}
    fields::Vector{String}    
    ts::Vector{String}
    methods::Vector{MethodStore}
    doc::String
end

struct genericStore <: SymStore
    t::String
    params::Vector{String}
    doc::String
end


function _getdoc(x)
    string(Docs.doc(x))
end

function read_methods(x)
    map(methods(x)) do m
        path = isabspath(String(m.file)) ? String(m.file) : Base.find_source_file(String(m.file))
        if path == nothing
            path = ""
        end
        MethodStore(path,
                    m.line,
                    Base.arg_decl_parts(m)[2][2:end])
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

function load_module(m, pkg, depot, out)
    out[".type"] = "module"
    out[".doc"] = string(Docs.doc(m))
    out[".exported"] = Set{String}(string.(names(m)))
    if haskey(depot["manifest"], first(pkg))
        for pkg1 in depot["manifest"][first(pkg)]
            if pkg1["uuid"] == last(pkg)
                for dep in get(pkg1, "deps", [])
                    try
                        depm = getfield(m, Symbol(first(dep)))                    
                        if !haskey(depot["packages"], last(dep))
                            depot["packages"][last(dep)] = Dict{String,Any}()
                            load_module(depm, dep, depot, depot["packages"][last(dep)])
                            out[first(dep)] = first(dep)
                        else
                            out[first(dep)] = first(dep)
                        end
                        # the above make reference to the name of the module, may have to change to uuid 
                    catch err
                    end
                end
            end
        end
    end
    for n in names(m, all = true)
        !isdefined(m, n) && continue
        startswith(string(n), "#") && continue
        if Base.isdeprecated(m, n)
        else
            x = getfield(m, n)
            if x isa Function
                out[String(n)] = FunctionStore(read_methods(x), _getdoc(x))
            elseif x isa DataType
                t, p = collect_params(x)
                if t.abstract
                    out[String(n)] = abstractStore(string.(p), _getdoc(x))
                elseif t.isbitstype
                        out[String(n)] = primitiveStore(string.(p), _getdoc(x))
                elseif !(isempty(t.types) || Base.isvatuple(t))
                        out[String(n)] = structStore(string.(p),
                                                     collect(string.(fieldnames(t))),
                                                     string.(collect(t.types)),
                                                     read_methods(x),
                                                     _getdoc(x))
                else
                    out[String(n)] = genericStore("DataType", string.(p), _getdoc(x))
                end
            elseif x isa Module && x != m # include reference to current module
                if parentmodule(x) == m # load non-imported submodules
                    out[String(n)] = Dict{String,Any}()
                    load_module(x, pkg, depot, out[String(n)])
                end
            else
                out[String(n)] = genericStore(string(typeof(x)), [], _getdoc(x))
            end
        end
    end
    out
end

function import_package(pkg, depot)
    depot["packages"][last(pkg)] = Dict{String,Any}()
    try
        Main.eval(:(import $(Symbol(first(pkg)))))
        m = getfield(Main, Symbol(first(pkg)))
        load_module(m, pkg, depot, depot["packages"][last(pkg)])
    catch err
    end
    return depot["packages"][last(pkg)]
end


function load_core()
    c = Pkg.Types.Context()    
    depot = Dict("manifest" => c.env.manifest, 
                 "installed" => c.env.project["deps"],
                 "packages" => Dict{String,Any}("Base" => Dict(), "Core" => Dict()))

    load_module(Base, "Base"=>"Base", depot, depot["packages"]["Base"])
    load_module(Core, "Core"=>"Core", depot, depot["packages"]["Core"])
    push!(depot["packages"]["Base"][".exported"], "include")

    return depot
end

function save_store_to_disc(store, file)
    io = open(file, "w")
    serialize(io, store)
    close(io)
end
