using LibGit2

mutable struct Server
    storedir::String
    context::Pkg.Types.Context
    depot::Dict
end

########## Fake type-system
# Used to label all objects
struct VarRef
    parent::Union{VarRef,Nothing}
    name::Symbol
end
VarRef(m::Module) = VarRef((parentmodule(m) == Main || parentmodule(m) == m) ? nothing : VarRef(parentmodule(m)), nameof(m))

# struct FakeModuleName
#     parent::Union{FakeModuleName,Nothing}
#     name::Symbol
# end
# FakeModuleName(m::Module) = FakeModuleName((parentmodule(m) == m || parentmodule(m) == Main) ? nothing : FakeModuleName(parentmodule(m)), nameof(m))

struct FakeTypeName
    name::Symbol
    parameters::Vector{Any}
    modul::VarRef
end

function FakeTypeName(x)
    if x isa DataType
        FakeTypeName(x.name.name, _parameter.(x.parameters), VarRef(x.name.module))
    elseif x isa Union
        FakeUnion(x)
    elseif x isa UnionAll
        FakeUnionAll(x)
    elseif x isa TypeVar
        FakeTypeVar(x)
    elseif x isa Core.TypeofBottom
        FakeTypeofBottom()
    else
        @info x, typeof(x)
        error()
    end
end

struct FakeTypeofBottom end
struct FakeUnion
    a
    b
    FakeUnion(u::Union) = new(FakeTypeName(u.a), FakeTypeName(u.b))
end
struct FakeTypeVar
    name::Symbol
    lb
    ub
    FakeTypeVar(tv::TypeVar) = new(tv.name, FakeTypeName(tv.lb), FakeTypeName(tv.ub))
end
struct FakeUnionAll
    var::FakeTypeVar
    body::Any
    FakeUnionAll(ua::UnionAll) = new(FakeTypeVar(ua.var), FakeTypeName(ua.body))
end


abstract type SymStore end
struct ModuleStore <: SymStore
    name::VarRef
    vals::Dict{Symbol,Any}
    doc::String
    exported::Bool
end
Base.getindex(m::ModuleStore, k) = m.vals[k]
Base.setindex!(m::ModuleStore, v, k) = (m.vals[k] = v)
Base.haskey(m::ModuleStore, k) = haskey(m.vals, k)

const EnvStore = Dict{Symbol,ModuleStore}

struct Package
    name::String
    val::ModuleStore
    ver::Any
    uuid::Base.UUID
    sha
end
Package(name::String, val::ModuleStore, ver, uuid::String, sha) = Package(name, val, ver, Base.UUID(uuid), sha) 

struct MethStore
    name::Symbol
    mod::Symbol
    file::String
    line::Int32
    sig::Vector{Pair{Any,Any}}
    rt::Any
end

struct DataTypeStore <: SymStore
    name::FakeTypeName
    super::FakeTypeName
    parameters::Vector{Any}
    types::Vector{Any}
    fieldnames::Vector{Symbol}
    methods::Vector{MethStore}
    doc::String
    exported::Bool
end

function DataTypeStore(t::DataType, parent_mod, exported)
    parameters = map(t.parameters) do p
        _parameter(p)
    end
    types = map(t.types) do p
        FakeTypeName(p)
    end
    DataTypeStore(FakeTypeName(t), FakeTypeName(t.super), parameters, types, Symbol[], cache_methods(t, parent_mod), _doc(t), exported)
end

struct FunctionStore <: SymStore
    name::VarRef
    methods::Vector{MethStore}
    doc::String
    extends::VarRef
    exported::Bool
end

function FunctionStore(f, parent_mod, exported)
    FunctionStore(VarRef(VarRef(parent_mod), nameof(f)), cache_methods(f, parent_mod), _doc(f), VarRef(VarRef(parentmodule(f)), nameof(f)), exported)
end

struct GenericStore <: SymStore
    name::VarRef
    typ::Any
    doc::String
    exported::Bool
end

function _parameter(p::T) where T
    if p isa Union{Int,Symbol,Bool,Char}
        p
    elseif !(p isa Type) && isbitstype(T)
        0
    elseif p isa Tuple
        _parameter.(p)
    else
        FakeTypeName(p)
    end
end

function clean_method_path(m::Method)
    path = String(m.file)
    if !isabspath(path) 
        path = Base.find_source_file(path)
        if path == nothing
            path = ""
        end
    end
    return path
end

function cache_methods(f, mod = nothing)
    if mod isa Module
        mod = (mod,)
    end
    if isa(f, Core.Builtin)
        return MethStore[]
    end
    types = Tuple
    world = typemax(UInt)
    params = Core.Compiler.Params(world)
    ms = MethStore[]
    for m in Base._methods(f, types, -1, world)
        if mod === nothing || m[3].module in mod
            # meth = Base.func_for_method_checked(m[3], types, m[2])
            if isdefined(m[3], :generator) && !Base.may_invoke_generator(m[3], types, m[2])
                ty = Any
            else
                try
                    ty = Core.Compiler.typeinf_type(m[3], m[1], m[2], params)
                catch e
                    ty = nothing
                end
                ty === nothing && (ty = Any)
            end
            MS = MethStore(m[3].name, nameof(m[3].module), clean_method_path(m[3]), m[3].line, [], FakeTypeName(ty))
            # Get signature
            sig = Base.unwrap_unionall(m[1])
            argnames = getargnames(m[3])
            for i = 2:m[3].nargs
                push!(MS.sig, argnames[i] => FakeTypeName(sig.parameters[i]))
            end
            push!(ms, MS)
        end
    end
    return ms
end

getargnames(m::Method) = Symbol.(split(m.slot_syms, "\0")[1:m.nargs])

function _functions()
    sts = Base.IdSet{Any}()
    visited = Base.IdSet{Module}()
    for m in Base.loaded_modules_array()
        InteractiveUtils._subtypes(m, Function, sts, visited)
    end
    return collect(sts)
end

function get_extended_methods(parent_mod::Module, allnames, store)
    for f in _functions()
        !hasproperty(f, :instance) && continue
        !isdefined(f, :instance) && continue
        !(f isa DataType) && continue
        haskey(store, f.name.name) && continue
        ms = cache_methods(f.instance, parent_mod)
        if !isempty(ms)
            store[nameof(f.instance)] = FunctionStore(VarRef(VarRef(f.name.module), nameof(f.instance)), ms, "", VarRef(VarRef(parentmodule(f)), nameof(f)), false)
        end
    end
end

function cache_module(m::Module, mname::VarRef = VarRef(m), pkg_deps = Symbol[])
    cache = ModuleStore(mname, Dict{Symbol,Any}(), _doc(m), false)
    allnames = names(m, all = true, imported = true)
    exportednames = names(m)
    for name in allnames
        !isdefined(m, name) && continue
        x = getfield(m, name)
        vname = VarRef(mname, name)
        if x isa Module
            (x == m || name == :Main) && continue
            if parentmodule(x) == m
                cache[name] = cache_module(x, VarRef(mname, name))
            else
                cache[name] = VarRef(x)
            end
        elseif x isa DataType
            cache[name] = DataTypeStore(x, m, name in exportednames)
        elseif x isa Function
            cache[name] = FunctionStore(x, m, name in exportednames)
        else
            cache[name] = GenericStore(VarRef(VarRef(m), name), FakeTypeName(typeof(x)), _doc(x), name in exportednames)
        end
    end
    get_extended_methods(m, allnames, cache)

    for d in pkg_deps
        if !haskey(cache, d) && isdefined(m, d) && getfield(m, d) isa Module
            x = getfield(m, d)
            cache[d] = VarRef(x)
        end
    end
    cache
end

function load_core()
    c = Pkg.Types.Context()
    depot = Dict{Symbol,Any}()
    depot[:Core] = cache_module(Core, VarRef(nothing, :Core))
    depot[:Base] = cache_module(Base, VarRef(nothing, :Base))

    # Add special cases
    let f = depot[:Base][:include]
        depot[:Base][:include] = FunctionStore(f.name, f.methods, f.doc, f.extends, true)
    end
    append!(depot[:Base][:include].methods, cache_methods(Base.MainInclude.include, Base.MainInclude))
    depot[:Base][:(var"@.")] = depot[:Base][:(var"@__dot__")]
    depot[:Core][:Main] = GenericStore(VarRef(nothing, :Main), FakeTypeName(Module),_doc(Main), true)
    # Add built-ins
    builtins = Symbol[nameof(f.instance) for f in subtypes(Core.Builtin) if f isa DataType && isdefined(f, :instance)]
    cnames = names(Core)
    for f in builtins
        if !haskey(depot[:Core], f)
            depot[:Core][f] = FunctionStore(getfield(Core, Symbol(f)), Core, Symbol(f) in cnames)
        end
        push!(depot[:Core][f].methods, MethStore(Symbol(f), :none, "built-in", 0, [], FakeTypeName(Any)))
    end
    haskey(depot[:Core], :_typevar) && push!(depot[:Core][:_typevar].methods, MethStore(:_typevar, :Core, "built-in", 0, [:n=>FakeTypeName(Symbol), :lb=>FakeTypeName(Any), :ub=>FakeTypeName(Any)], FakeTypeName(Any)))
    push!(depot[:Core][:setproperty!].methods, MethStore(:setproperty!, :Core, "built-in", 0, [:value => FakeTypeName(Any), :name => FakeTypeName(Symbol), :x => FakeTypeName(Any)],FakeTypeName(Any)))
    push!(depot[:Core][:_apply_latest].methods, MethStore(:_apply_latest, :Core, "built-in", 0, [:f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any,N} where N)], FakeTypeName(Any)))
    push!(depot[:Core][:_apply_pure].methods, MethStore(:_apply_pure, :Core, "built-in", 0, [:f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any,N} where N)], FakeTypeName(Any)))
    push!(depot[:Core][:getproperty].methods, MethStore(:getproperty, :Core, "built-in", 0, [:value => FakeTypeName(Any), :name => FakeTypeName(Symbol)], FakeTypeName(Any)))
    push!(depot[:Core][:ifelse].methods, MethStore(:ifelse, :Core, "built-in", 0, [:condition => FakeTypeName(Bool), :x => FakeTypeName(Any), :y => FakeTypeName(Any)], FakeTypeName(Any)))
    haskey(depot[:Core], :const_arrayref) && push!(depot[:Core][:const_arrayref].methods, MethStore(:const_arrayref, :Core, "built-in", 0, [:args => FakeTypeName(Vararg{Any,N} where N)], FakeTypeName(Any)))
    
    depot[:Core][:ccall] = FunctionStore(VarRef(VarRef(Core), :ccall),
        MethStore[
            MethStore(:ccall, :Core, "built-in", 0, [:args => FakeTypeName(Vararg{Any,N} where N)], FakeTypeName(Any)) # General method - should be fixed
        ],
        "`ccall((function_name, library), returntype, (argtype1, ...), argvalue1, ...)`\n`ccall(function_name, returntype, (argtype1, ...), argvalue1, ...)`\n`ccall(function_pointer, returntype, (argtype1, ...), argvalue1, ...)`\n\nCall a function in a C-exported shared library, specified by the tuple (`function_name`, `library`), where each component is either a string or symbol. Instead of specifying a library, one\ncan also use a `function_name` symbol or string, which is resolved in the current process. Alternatively, `ccall` may also be used to call a function pointer `function_pointer`, such as one\nreturned by `dlsym`.\n\nNote that the argument type tuple must be a literal tuple, and not a tuple-valued variable or expression.\n\nEach `argvalue` to the `ccall` will be converted to the corresponding `argtype`, by automatic insertion of calls to `unsafe_convert(argtype, cconvert(argtype, argvalue))`. (See also the documentation for `unsafe_convert` and `cconvert` for further details.) In most cases, this simply results in a call to `convert(argtype, argvalue)`.", 
        VarRef(VarRef(Core), :ccall), 
        true)
    depot[:Core][:(var"@__doc__")] = FunctionStore(VarRef(VarRef(Core), :(var"@__doc__")), cache_methods(getfield(Core, :(var"@__doc__"))), "", VarRef(VarRef(Core), :(var"@__doc__")), true)
    return depot
end

function cache_package(c::Pkg.Types.Context, uuid, depot::Dict, conn)
    uuid in keys(depot) && return
    isinmanifest(c, uuid isa String ? Base.UUID(uuid) : uuid) || return
    
    pe = frommanifest(c, uuid)
    pe_name = packagename(c, uuid)
    pid = Base.PkgId(uuid isa String ? Base.UUID(uuid) : uuid, pe_name)

    if pid in keys(Base.loaded_modules)
        conn!==nothing && println(conn, "PROCESSPKG;$pe_name;$uuid;noversion")        
        LoadingBay.eval(:($(Symbol(pe_name)) = $(Base.loaded_modules[pid])))
        m = getfield(LoadingBay, Symbol(pe_name))
    else
        m = try
            conn!==nothing && println(conn, "STARTLOAD;$pe_name;$uuid;noversion")
            LoadingBay.eval(:(import $(Symbol(pe_name))))
            conn!==nothing && println(conn, "STOPLOAD;$pe_name")
            m = getfield(LoadingBay, Symbol(pe_name))
        catch e
            depot[uuid] = Package(pe_name, ModuleStore(VarRef(nothing, Symbol(pe_name)), Dict(), "Failed to load package.", false), version(pe), uuid, sha_pkg(pe))
            return
        end
    end
    depot[uuid] = Package(pe_name, cache_module(m, VarRef(m), Symbol.(collect(keys(deps(pe))))), version(pe), uuid, sha_pkg(pe))

    pe_path = pathof(m) isa String && !isempty(pathof(m)) ? joinpath(dirname(pathof(m)), "..") : nothing

    # Dependencies
    for pkg in deps(pe)
        cache_package(c, packageuuid(pkg), depot, conn)
    end

    return
end
