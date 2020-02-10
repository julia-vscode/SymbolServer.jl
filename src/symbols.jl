using LibGit2

mutable struct Server
    storedir::String
    context::Pkg.Types.Context
    depot::Dict
end

struct PackageRef{N}
    name::NTuple{N,String}
end

struct TypeRef{N}
    name::String
    mod::PackageRef{N}
end
TypeRef(t::TypeVar) = TypeRef("Any", PackageRef(("Core",)))
TypeRef(t::Union) = TypeRef("Any", PackageRef(("Core",)))
TypeRef(t::Type{T}) where T = TypeRef("Any", PackageRef(("Core",)))
TypeRef(t::UnionAll) = TypeRef(Base.unwrap_unionall(t))
function TypeRef(t::DataType)
    pm = String.(split(string(Base.parentmodule(t)), "."))
    pr = TypeRef(String(t.name.name), PackageRef(ntuple(i->pm[i], length(pm))))
end
Base.string(tr::TypeRef{T}) where T = string("TypeRef: ", join(tr.mod.name, "."), ".", tr.name)

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
Package(name::String, val::ModuleStore, ver, uuid::String, sha) = Package(name, val, ver, Base.UUID(uuid), sha) 

struct MethodStore <: SymStore
    file::String
    line::Int
    args::Vector{Tuple{String,String}}
end

struct FunctionStore <: SymStore
    methods::Vector{MethodStore}
    doc::String
    extends::Union{Nothing,PackageRef}
end

struct DataTypeStore <: SymStore
    params::Vector{String}
    fields::Vector{String}
    ts::Vector{TypeRef}
    methods::Vector{MethodStore}
    doc::String
end

struct genericStore <: SymStore
    t::String
    params::Vector{String}
    doc::String
end

function _getdoc(x)
    string(BaseShow._doc((x)))
end

# v1.4 compat for change in kwarg_decl signature
@static if length(first(methods(Base.kwarg_decl)).sig.parameters) == 2
    kwarg_decl(m::Method, b) = Base.kwarg_decl(m)
else
    kwarg_decl = Base.kwarg_decl
end

function _parentmodules_comp(m::Module, M)
    if m == M
        return true
    elseif parentmodule(m) != m
        return _parentmodules_comp(parentmodule(m), M)
    else
        return false
    end
end

function _lookup(tr::PackageRef{N}, depot::Dict{String,ModuleStore}) where N
    if haskey(depot, tr.name[1])
        if N == 1
            return depot[tr.name[1]]
        else
            return _lookup(tr, depot[tr.name[1]], 2)
        end
    end
end

function _lookup(tr::PackageRef{N}, m::ModuleStore, i) where N
    if i < N && haskey(m.vals, tr.name[i])
        _lookup(tr, m.vals[tr.name[i]], i + 1)
    elseif i == N && haskey(m.vals, tr.name[i])
        return m.vals[tr.name[i]]
    end
end

function read_methods(x, M)
    if x isa Core.IntrinsicFunction
        return MethodStore[MethodStore("intrinsic-function", 0, [("args...", "Any")])]
    end
    ms = methods(x)
    ms1 = MethodStore[]
    for m in ms
        # !_parentmodules_comp(m.module, M) && parentmodule(x) != m && continue
        path = isabspath(String(m.file)) ? String(m.file) : Base.find_source_file(String(m.file))
        if path === nothing
            path = ""
        end
        args = Base.invokelatest(BaseShow._arg_decl_parts, m)[2][2:end]
        if isdefined(ms.mt, :kwsorter)
            kws = kwarg_decl(m, typeof(ms.mt.kwsorter))
            for kw in kws
                push!(args, (string(kw), ".KW"))
            end
        end
        for i = 1:length(args)
            if isempty(args[i][2])
                args[i] = (args[i][1], "Any")
            end
        end
        push!(ms1, MethodStore(path,
                    m.line,
                    args))
    end
    for i in 1:length(ms1)
        for j = i + 1:length(ms1)
            if ms1[i].file == ms1[j].file && ms1[i].line == ms1[j].line
                if length(ms1[i].args) < length(ms1[j].args) &&
                    ms1[i].args == ms1[j].args[1:length(ms1[i].args)]
                    kws = filter(a->last(a) == ".KW", ms1[j].args)
                    if !isempty(kws)
                        append!(ms1[i].args, ms1[j].args[end - length(kws) + 1:end])
                    end
                end
            end
        end
    end
    ms1
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
    depot["Core"] = get_module(Core)
    depot["Base"] = get_module(Base)

    # Add special cases
    push!(depot["Base"].exported, "include")
    append!(depot["Base"].vals["include"].methods, read_methods(Base.MainInclude.include, Base.MainInclude))
    depot["Base"].vals["@."] = depot["Base"].vals["@__dot__"]
    push!(depot["Base"].exported, "@.")
    depot["Core"].vals["Main"] = genericStore("Module", [], _getdoc(Main))
    # Add built-ins
    builtins = (split("=== typeof sizeof <: isa typeassert throw tuple getfield setfield! fieldtype nfields isdefined arrayref arrayset arraysize applicable invoke apply_type _apply _expr svec"))
    for f in builtins
        if haskey(depot["Core"].vals, f)
            push!(depot["Core"].vals[f].methods, MethodStore("built-in", 0, [("args...", "Any")]))
        else
            depot["Core"].vals[f] = FunctionStore(MethodStore[MethodStore("built-in", 0, [("args...", "Any")])], _getdoc(getfield(Core, Symbol(f))), nothing)
        end
    end
    haskey(depot["Core"].vals, "_typevar") && push!(depot["Core"].vals["_typevar"].methods, MethodStore("built-in", 0, [("n", "Symbol"), ("lb", "Any"), ("ub", "Any")]))
    push!(depot["Core"].vals["setproperty!"].methods, MethodStore("built-in", 0, [("value", "Any"), ("name", "Symbol"), ("x", "Any")]))
    push!(depot["Core"].vals["_apply_latest"].methods, MethodStore("built-in", 0, [("f", "Function"), ("args...", "Any")]))
    push!(depot["Core"].vals["_apply_pure"].methods, MethodStore("built-in", 0, [("f", "Function"), ("args...", "Any")]))
    push!(depot["Core"].vals["getproperty"].methods, MethodStore("built-in", 0, [("value", "Any"), ("name", "Symbol")]))
    push!(depot["Core"].vals["ifelse"].methods, MethodStore("built-in", 0, [("condition", "Bool"), ("x", "Any"), ("y", "Any")]))
    haskey(depot["Core"].vals, "const_arrayref") && push!(depot["Core"].vals["const_arrayref"].methods, MethodStore("built-in", 0, [("args...", "Any")]))

    push!(depot["Core"].exported, "ccall")
    depot["Core"].vals["ccall"] = FunctionStore(MethodStore[MethodStore("built-in", 0, [("(function_name, library", "Any"), ("returntype", "Any"), ("(argtype1, ...", "Tuple"), ("argvalue1, ...", "Any")])], "`ccall((function_name, library), returntype, (argtype1, ...), argvalue1, ...)`\n`ccall(function_name, returntype, (argtype1, ...), argvalue1, ...)`\n`ccall(function_pointer, returntype, (argtype1, ...), argvalue1, ...)`\n\nCall a function in a C-exported shared library, specified by the tuple (`function_name`, `library`), where each component is either a string or symbol. Instead of specifying a library, one\ncan also use a `function_name` symbol or string, which is resolved in the current process. Alternatively, `ccall` may also be used to call a function pointer `function_pointer`, such as one\nreturned by `dlsym`.\n\nNote that the argument type tuple must be a literal tuple, and not a tuple-valued variable or expression.\n\nEach `argvalue` to the `ccall` will be converted to the corresponding `argtype`, by automatic insertion of calls to `unsafe_convert(argtype, cconvert(argtype, argvalue))`. (See also the documentation for `unsafe_convert` and `cconvert` for further details.) In most cases, this simply results in a call to `convert(argtype, argvalue)`.", nothing)
    depot["Core"].vals["@__doc__"] = FunctionStore(read_methods(getfield(Core, Symbol("@__doc__")), Core), _getdoc(getfield(Core, Symbol("@__doc__"))), nothing)
    return depot
end

function get_module(m::Module, pkg_deps = Set{String}())
    out = ModuleStore(string(Base.nameof(m)))
    out.doc = string(BaseShow._doc(m))
    out.exported = Set{String}(string.(names(m)))
    allnames = names(m, all = true, imported = true)
    for n in allnames
        !isdefined(m, n) && continue
        startswith(string(n), "#") && continue
        Base.isdeprecated(m, n) && continue
        try
            x = getfield(m, n)
            t, p = collect_params(x)
            if x isa Function
                if parentmodule(x) == x 
                    extends = nothing
                else
                    pm = String.(split(string(Base.parentmodule(x)), "."))
                    extends = PackageRef(ntuple(i-> pm[i], length(pm)))
                end
                out.vals[String(n)] = FunctionStore(read_methods(x, m), _getdoc(x), extends)
            elseif t isa DataType
                out.vals[String(n)] = DataTypeStore(string.(p),
                                hasfields(t) ? collect(string.(fieldnames(t))) : String[],
                                get_fieldtypes(t),
                                t == Vararg ? [] : read_methods(x, m),
                                _getdoc(x))
            elseif x isa Module && x != m # include reference to current module
                n == :Main && continue
                if parentmodule(x) == m # load non-imported submodules
                    out.vals[String(n)] = get_module(x, pkg_deps)

                else
                    pm = String.(split(string(Base.parentmodule(x)), "."))
                    out.vals[String(n)] = PackageRef(ntuple(i->i <= length(pm) ? pm[i] : string(Base.nameof(x)), length(pm) + 1))
                end
            else
                out.vals[String(n)] = genericStore(string(typeof(x)), [], _getdoc(x))
            end
        catch err
            out.vals[String(n)] = genericStore("Any", [], "Variable could not be cached.")
        end
    end

    for d in pkg_deps
        if !haskey(out.vals, Symbol(d)) && isdefined(m, Symbol(d))
            x = getfield(m, Symbol(d))
            pm = String.(split(string(Base.parentmodule(x)), "."))
            if Base.parentmodule(x) == x
                out.vals[d] = PackageRef(ntuple(i->pm[i], length(pm)))
            else
                out.vals[d] = PackageRef(ntuple(i->i <= length(pm) ? pm[i] : string(Base.nameof(x)), length(pm) + 1))
            end
        end
    end

    out
end

function cache_package(c::Pkg.Types.Context, uuid, depot::Dict)
    uuid in keys(depot) && return true

    pe = frommanifest(c, uuid)
    pe_name = packagename(c, uuid)
    pid = Base.PkgId(uuid isa String ? Base.UUID(uuid) : uuid, pe_name)

    if pid in keys(Base.loaded_modules)
        LoadingBay.eval(:($(Symbol(pe_name)) = $(Base.loaded_modules[pid])))
        m = getfield(LoadingBay, Symbol(pe_name))
    else
        m = try
            LoadingBay.eval(:(import $(Symbol(pe_name))))
            m = getfield(LoadingBay, Symbol(pe_name))
        catch e
            depot[uuid] = Package(pe_name, ModuleStore(pe_name), version(pe), uuid, sha_pkg(pe))
            return false
        end
    end
    depot[uuid] = Package(pe_name, get_module(m, Set(keys(deps(pe)))), version(pe), uuid, sha_pkg(pe))

    pe_path = pathof(m) isa String && !isempty(pathof(m)) ? joinpath(dirname(pathof(m)), "..") : nothing

    # Dependencies
    for pkg in deps(pe)
        cache_package(c, packageuuid(pkg), depot)
    end

    return true
end
