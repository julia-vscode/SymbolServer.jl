using LibGit2

mutable struct Server
    storedir::String
    context::Pkg.Types.Context
    depot::Dict
end

struct PackageRef{N}
    name::NTuple{N,String}
end

abstract type SymStore end
mutable struct ModuleStore <: SymStore
    name::String
    vals::Dict{String,Any}
    exported::Set{String}
    doc::String
end
ModuleStore(name::String) = ModuleStore(name, Dict{String,Any}(), Set{String}(), "")

struct Package
    name::String
    val::ModuleStore
    ver::Any
    uuid::Base.UUID
    sha
end

struct MethodStore <: SymStore
    file::String
    line::Int
    args::Vector{Tuple{String,String}}
end

struct FunctionStore <: SymStore
    methods::Vector{MethodStore}
    doc::String
end

struct DataTypeStore <: SymStore
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
    # Packages can add methods to Docs.doc, and those can have a bug,
    # and we don't want that to kill the symbol server process
    try
        return string(Docs.doc(x))
    catch err
        @warn "Couldn't retrieve docs."
        return ""
    end
end

function read_methods(x)
    ms = methods(x)
    map(ms) do m
        path = isabspath(String(m.file)) ? String(m.file) : Base.find_source_file(String(m.file))
        if path === nothing
            path = ""
        end
        args = Base.arg_decl_parts(m)[2][2:end]
        if isdefined(ms.mt, :kwsorter)
            kws = Base.kwarg_decl(m, typeof(ms.mt.kwsorter))
            for kw in kws
                push!(args, (string(kw), ".KW"))
            end
        end
        for i = 1:length(args)
            if isempty(args[i][2])
                args[i] = (args[i][1], "Any")
            end
        end
        MethodStore(path,
                    m.line,
                    args)
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

function load_core()
    c = Pkg.Types.Context()
    depot = Dict{String,Any}()
    depot["Core"] = get_module(c, Core)
    depot["Base"] = get_module(c, Base)

    # Add special cases
    push!(depot["Base"].exported, "include")
    depot["Base"].vals["@."] = depot["Base"].vals["@__dot__"]
    push!(depot["Base"].exported, "@.")
    delete!(depot["Core"].exported, "Main")
    # Add built-ins
    builtins = (split("=== typeof sizeof <: isa typeassert throw tuple getfield setfield! fieldtype nfields isdefined arrayref arrayset arraysize applicable invoke apply_type _apply _expr svec"))
    for f in builtins
        if haskey(depot["Core"].vals, f)
            push!(depot["Core"].vals[f].methods, MethodStore("built-in", 0, [("args...", "Any")]))
        else
            depot["Core"].vals[f] = FunctionStore(MethodStore[MethodStore("built-in", 0, [("args...", "Any")])], _getdoc(getfield(Core, Symbol(f))))
        end
    end
    return depot
end

function get_module(c::Pkg.Types.Context, m::Module)
    out = ModuleStore(string(Base.nameof(m)))
    out.doc = string(Docs.doc(m))
    out.exported = Set{String}(string.(names(m)))
    allnames = names(m, all = true, imported = true)
    for n in allnames
        !isdefined(m, n) && continue
        startswith(string(n), "#") && continue
        if Base.isdeprecated(m, n)
        else
            x = getfield(m, n)
            t, p = collect_params(x)
            if x isa Function
                out.vals[String(n)] = FunctionStore(read_methods(x), _getdoc(x))
            elseif t isa DataType
                if t.abstract || t.isbitstype
                    out.vals[String(n)] = DataTypeStore(string.(p), [], [], [], _getdoc(x))
                elseif isdefined(t, :types) && !isempty(t.types) && !Base.isvatuple(t)
                    out.vals[String(n)] = DataTypeStore(string.(p),
                                                     collect(string.(fieldnames(t))),
                                                     string.(collect(t.types)),
                                                     read_methods(x),
                                                     _getdoc(x))
                else
                    out.vals[String(n)] = DataTypeStore(string.(p), [], [], [], _getdoc(x))
                end
            elseif x isa Module && x != m # include reference to current module
                n == :Main && continue
                if parentmodule(x) == m # load non-imported submodules
                    out.vals[String(n)] = get_module(c, x)
                    
                else
                    pm = String.(split(string(Base.parentmodule(x)), "."))
                    out.vals[String(n)] = PackageRef(ntuple(i->i <= length(pm) ? pm[i] : string(Base.nameof(x)), length(pm) + 1))
                end
            else
                out.vals[String(n)] = genericStore(string(typeof(x)), [], _getdoc(x))
            end
        end
    end
    out
end

function cache_package(c::Pkg.Types.Context, uuid::UUID, depot::Dict, env_path = dirname(c.env.manifest_file))
    uuid in keys(depot) && return true
    # pe = manifest(c)[uuid]
    pe = frommanifest(c, uuid)
    pe_name = packagename(c, uuid)
    old_env_path = env_path
    m = try
        Main.eval(:(import $(Symbol(pe_name))))
        m = getfield(Main, Symbol(pe_name))
        depot[uuid] = Package(pe_name, get_module(c, m), version(pe), uuid, sha_pkg(pe))
    catch err
        try
            m = tryaccess(getfield(Main, Symbol(packagename(c, first(find_parent(c, uuid))))), Symbol(pe_name))
            depot[uuid] = Package(pe_name, get_module(c, m), version(pe), uuid, sha_pkg(pe))
        catch err1
            @info "Failed to load $uuid [$(pe_name)] from $env_path"
            depot[uuid] = Package(pe_name, ModuleStore(pe_name), version(pe), uuid, sha_pkg(pe))
            return false
        end
    end

    # Dependencies
    for pkg in deps(pe)
        if path(pe) isa String 
            env_path = path(pe)
            Pkg.API.activate(env_path)
        elseif !Pkg.Types.is_stdlib(c, uuid) && ((Pkg.API.dir(pe_name) isa String) && !isempty(Pkg.API.dir(pe_name)))
            env_path = Pkg.API.dir(pe_name)
            Pkg.API.activate(env_path)
        end
        cache_package(c, packageuuid(pkg), depot, env_path)
    end

    Pkg.API.activate(old_env_path)
    return true
end
