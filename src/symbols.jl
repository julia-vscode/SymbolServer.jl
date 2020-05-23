using LibGit2

mutable struct Server
    storedir::String
    context::Pkg.Types.Context
    depot::Dict
end

abstract type SymStore end
struct ModuleStore <: SymStore
    name::VarRef
    vals::Dict{Symbol,Any}
    doc::String
    exported::Bool
    exportednames::Vector{Symbol}
    used_modules::Vector{Symbol}
end

ModuleStore(m) = ModuleStore(VarRef(m), Dict{Symbol,Any}(), "", true, names(m), Symbol[])
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

struct MethodStore
    name::Symbol
    mod::Symbol
    file::String
    line::Int32
    sig::Vector{Pair{Any,Any}}
    kws::Vector{Symbol}
    rt::Any
end

struct DataTypeStore <: SymStore
    name::FakeTypeName
    super::FakeTypeName
    parameters::Vector{Any}
    types::Vector{Any}
    fieldnames::Vector{Any}
    methods::Vector{MethodStore}
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
    DataTypeStore(FakeTypeName(t), FakeTypeName(t.super), parameters, types, t.isconcretetype && fieldcount(t) > 0 ? collect(fieldnames(t)) : Symbol[], cache_methods(t, parent_mod, exported), _doc(t), exported)
end

struct FunctionStore <: SymStore
    name::VarRef
    methods::Vector{MethodStore}
    doc::String
    extends::VarRef
    exported::Bool
end

function FunctionStore(f, parent_mod, exported)
    FunctionStore(VarRef(VarRef(parent_mod), nameof(f)), cache_methods(f, parent_mod, exported), _doc(f), VarRef(VarRef(parentmodule(f)), nameof(f)), exported)
end

struct GenericStore <: SymStore
    name::VarRef
    typ::Any
    doc::String
    exported::Bool
end


function clean_method_path(m::Method)
    path = String(m.file)
    if !isabspath(path) 
        path = Base.find_source_file(path)
        if path === nothing
            path = ""
        end
    end
    return path
end

function cache_methods(f, mod = nothing, exported = false)
    if isa(f, Core.Builtin)
        return MethodStore[]
    end
    types = Tuple
    world = typemax(UInt)
    params = Core.Compiler.Params(world)
    ms = MethodStore[]
    methods0 = try
        Base._methods(f, types, -1, world)
    catch err
        return ms
    end
    ind_of_method_w_kws = Int[] # stores the index of methods with kws.
    i = 1
    for m in methods0
        if mod === nothing || mod === m[3].module
            if true # Get return types? setting to false is costly
                ty = Any
            elseif isdefined(m[3], :generator) && !Base.may_invoke_generator(m[3], types, m[2])
                ty = Any
            else
                try
                    ty = Core.Compiler.typeinf_type(m[3], m[1], m[2], params)
                catch e
                    ty = nothing
                end
                ty === nothing && (ty = Any)
            end
            MS = MethodStore(m[3].name, nameof(m[3].module), clean_method_path(m[3]), m[3].line, [], Symbol[], FakeTypeName(ty))
            # Get signature
            sig = Base.unwrap_unionall(m[1])
            argnames = getargnames(m[3])
            for i = 2:m[3].nargs
                push!(MS.sig, argnames[i] => FakeTypeName(sig.parameters[i]))
            end
            kws = getkws(m[3])
            if !isempty(kws)
                push!(ind_of_method_w_kws, i)
            end
            for kw in kws
                push!(MS.kws, kw)
            end
            push!(ms, MS)
            i +=1 
        end
    end
    # Go back and add kws to methods defined in the same place as others with kws.
    for i in ind_of_method_w_kws
        for j = 1:length(ms) # only need to go up to `i`?
            if ms[j].file == ms[i].file && ms[j].line == ms[i].line && isempty(ms[j].kws)
                for kw in ms[i].kws
                    push!(ms[j].kws, kw)
                end
            end
        end
    end
    return ms
end

getargnames(m::Method) = Base.method_argnames(m)
@static if length(first(methods(Base.kwarg_decl)).sig.parameters) == 2
    getkws = Base.kwarg_decl
else
    function getkws(m::Method) 
        sig = Base.unwrap_unionall(m.sig)
        length(sig.parameters) == 0 && return []
        sig.parameters[1] isa Union && return []
        !isdefined(Base.unwrap_unionall(sig.parameters[1]), :name) && return []
        fname = Base.unwrap_unionall(sig.parameters[1]).name
        if isdefined(fname.mt, :kwsorter)
            Base.kwarg_decl(m, typeof(fname.mt.kwsorter))
        else 
            []
        end
    end
end

function apply_to_everything(f, m = nothing, visited = Base.IdSet{Module}())
    if m isa Module
        push!(visited, m)
        for s in names(m, all = true)
            (!isdefined(m, s) || s == nameof(m)) && continue
            x = getfield(m, s)
            f(x)
            if x isa Module && !in(x, visited)
                apply_to_everything(f, x, visited)
            end
        end
    else
        for m in Base.loaded_modules_array()
            in(m, visited) || apply_to_everything(f, m, visited)
        end
    end
end



function oneverything(f, m = nothing, visited = Base.IdSet{Module}())
    if m isa Module
        push!(visited, m)
        for s in names(m, all = true)
            !isdefined(m, s) && continue
            x = getfield(m, s)
            f(m, s, x)
            if x isa Module && !in(x, visited)
                oneverything(f, x, visited)
            end
        end
    else
        for m in Base.loaded_modules_array()
            in(m, visited) || oneverything(f, m, visited)
        end
    end
end

function allnames() 
    symbols = Base.IdSet{Symbol}()
    oneverything((m, s, x)->push!(symbols, s))
    return symbols
end

function allmodulenames() 
    symbols = Base.IdSet{Symbol}()
    oneverything((m, s, x)->(x isa Module && push!(symbols, s)))
    return symbols
end

function allthingswithmethods() 
    symbols = Base.IdSet{Any}()
    oneverything(function (m, s, x) 
    if !Base.isvarargtype(x) && !isempty(methods(x))
        push!(symbols, x)
    end
    end)
    return symbols
end

function allmethods() 
    ms = Method[]
    oneverything(function (m, s, x) 
    if !Base.isvarargtype(x) && !isempty(methods(x))
        append!(ms, methods(x))
    end
    end)
    return ms
end

usedby(outer, inner) = outer !== inner && isdefined(outer, nameof(inner)) && getproperty(outer, nameof(inner)) === inner && all(isdefined(outer, name) || !isdefined(inner, name) for name in names(inner))
istoplevelmodule(m) = parentmodule(m) === m || parentmodule(m) === Main

function getmoduletree(m::Module, amn, visited = Base.IdSet{Module}())
    push!(visited, m)
    cache = ModuleStore(m)
    for s in names(m, all = true)
        !isdefined(m, s) && continue
        x = getfield(m, s)
        if x isa Module
            if istoplevelmodule(x)
                cache[s] = VarRef(x)
            elseif m === parentmodule(x)
                cache[s] = getmoduletree(x, amn, visited)
            else
                cache[s] = VarRef(x)
            end
        end
    end
    for n in amn
        if n !== nameof(m) && isdefined(m, n)
            x = getfield(m, n)
            if x isa Module 
                if !istoplevelmodule(x) && !haskey(cache, n)
                    cache[n] = VarRef(x)
                end
                if usedby(m, x)
                    push!(cache.used_modules, n)
                end
            end
        end
    end
    cache
end

function getenvtree(names = nothing)
    amn = allmodulenames()
    EnvStore(nameof(m) => getmoduletree(m, amn) for m in Base.loaded_modules_array() if names === nothing || nameof(m) in names)
end

function symbols(env, m = nothing, an = allnames(), visited = Base.IdSet{Module}())
    if m isa Module
        cache = _lookup(VarRef(m), env, true)
        cache === nothing && return 
        push!(visited, m)
        for s in an
            !isdefined(m, s) && continue
            x = getfield(m, s)
            if x isa DataType
                if parentmodule(x) === m 
                    cache[s] = DataTypeStore(x, m, s in names(m))
                else
                    cache[s] = FunctionStore(x, m, s in names(m))
                end
            elseif x isa Function
                if parentmodule(x) === m 
                    cache[s] = FunctionStore(x, m, s in names(m))
                elseif any(met.module == m for met in methods(x))
                    cache[s] = FunctionStore(x, m, s in names(m))
                else
                    cache[s] = VarRef(VarRef(parentmodule(x)), nameof(x))
                end
            elseif x isa Module
                if x === m
                    cache[s] = VarRef(x)
                elseif parentmodule(x) === m
                    symbols(env, x, an, visited)
                else
                    cache[s] = VarRef(x)
                end 
            else
                cache[s] = GenericStore(VarRef(VarRef(m), s), FakeTypeName(typeof(x)), _doc(x), s in names(m))
            end
        end
    else
        for m in Base.loaded_modules_array()
            in(m, visited) || symbols(env, m, an, visited)
        end
    end
end


function load_core()
    c = Pkg.Types.Context()
    cache = getenvtree([:Core,:Base])
    symbols(cache)

    # Add special cases for built-ins
    let f = cache[:Base][:include]
        cache[:Base][:include] = FunctionStore(f.name, f.methods, f.doc, f.extends, true)
    end
    append!(cache[:Base][:include].methods, cache_methods(Base.MainInclude.include, Base.MainInclude))
    cache[:Base][Symbol("@.")] = cache[:Base][Symbol("@__dot__")]
    cache[:Core][:Main] = GenericStore(VarRef(nothing, :Main), FakeTypeName(Module),_doc(Main), true)
    # Add built-ins
    builtins = Symbol[nameof(getfield(Core,n).instance) for n in names(Core, all = true) if isdefined(Core, n) && getfield(Core, n) isa DataType && isdefined(getfield(Core, n), :instance) && getfield(Core, n).instance isa Core.Builtin]
    cnames = names(Core)
    for f in builtins
        if !haskey(cache[:Core], f)
            cache[:Core][f] = FunctionStore(getfield(Core, Symbol(f)), Core, Symbol(f) in cnames)
        end
        push!(cache[:Core][f].methods, MethodStore(Symbol(f), :none, "built-in", 0, [], Symbol[], FakeTypeName(Any)))
    end
    haskey(cache[:Core], :_typevar) && push!(cache[:Core][:_typevar].methods, MethodStore(:_typevar, :Core, "built-in", 0, [:n=>FakeTypeName(Symbol), :lb=>FakeTypeName(Any), :ub=>FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:_apply].methods, MethodStore(:_apply, :Core, "built-in", 0, [:f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any,N} where N)], Symbol[], FakeTypeName(Any)))
    haskey(cache[:Core].vals, :_apply_iterate) && push!(cache[:Core][:_apply_iterate].methods, MethodStore(:_apply_iterate, :Core, "built-in", 0, [:f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any,N} where N)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:_apply_latest].methods, MethodStore(:_apply_latest, :Core, "built-in", 0, [:f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any,N} where N)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:_apply_pure].methods, MethodStore(:_apply_pure, :Core, "built-in", 0, [:f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any,N} where N)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:_expr].methods, MethodStore(:_expr, :Core, "built-in", 0, [:head => FakeTypeName(Symbol), :args => FakeTypeName(Vararg{Any,N} where N)], Symbol[], FakeTypeName(Expr)))
    haskey(cache[:Core].vals, :_typevar) && push!(cache[:Core][:_typevar].methods, MethodStore(:_typevar, :Core, "built-in", 0, [:name => FakeTypeName(Symbol), :lb => FakeTypeName(Any), :ub => FakeTypeName(Any)], Symbol[], FakeTypeName(TypeVar)))
    push!(cache[:Core][:applicable].methods, MethodStore(:applicable, :Core, "built-in", 0, [:f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any,N} where N)], Symbol[], FakeTypeName(Bool)))
    push!(cache[:Core][:apply_type].methods, MethodStore(:apply_type, :Core, "built-in", 0, [:T => FakeTypeName(UnionAll), :types => FakeTypeName(Vararg{Any,N} where N)], Symbol[], FakeTypeName(UnionAll)))
    push!(cache[:Core][:arrayref].methods, MethodStore(:arrayref, :Core, "built-in", 0, [:a => FakeTypeName(Any), :b => FakeTypeName(Any), :c => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:arrayset].methods, MethodStore(:arrayset, :Core, "built-in", 0, [:a => FakeTypeName(Any), :b => FakeTypeName(Any), :c => FakeTypeName(Any), :d => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:arraysize].methods, MethodStore(:arraysize, :Core, "built-in", 0, [:a => FakeTypeName(Array), :i => FakeTypeName(Int)], Symbol[], FakeTypeName(Int)))
    haskey(cache[:Core], :const_arrayref) && push!(cache[:Core][:const_arrayref].methods, MethodStore(:const_arrayref, :Core, "built-in", 0, [:args => FakeTypeName(Vararg{Any,N} where N)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:fieldtype].methods, MethodStore(:fieldtype, :Core, "built-in", 0, [:t => FakeTypeName(DataType), :field => FakeTypeName(Symbol)], Symbol[], FakeTypeName(Type)))
    push!(cache[:Core][:getfield].methods, MethodStore(:setfield, :Core, "built-in", 0, [:object => FakeTypeName(Any), :item => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:ifelse].methods, MethodStore(:ifelse, :Core, "built-in", 0, [:condition => FakeTypeName(Bool), :x => FakeTypeName(Any), :y => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:invoke].methods, MethodStore(:invoke, :Core, "built-in", 0, [:f => FakeTypeName(Function), :x => FakeTypeName(Any), :argtypes => FakeTypeName(Type) , :args => FakeTypeName(Vararg{Any,N} where N)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:isa].methods, MethodStore(:isa, :Core, "built-in", 0, [:a => FakeTypeName(Any), :T => FakeTypeName(Type)], Symbol[], FakeTypeName(Bool)))
    push!(cache[:Core][:isdefined].methods, MethodStore(:getproperty, :Core, "built-in", 0, [:value => FakeTypeName(Any), :field => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:nfields].methods, MethodStore(:nfields, :Core, "built-in", 0, [:x => FakeTypeName(Any)], Symbol[], FakeTypeName(Int)))
    push!(cache[:Core][:setfield!].methods, MethodStore(:setfield!, :Core, "built-in", 0, [:value => FakeTypeName(Any), :name => FakeTypeName(Symbol), :x => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:sizeof].methods, MethodStore(:sizeof, :Core, "built-in", 0, [:obj => FakeTypeName(Any)], Symbol[], FakeTypeName(Int)))
    push!(cache[:Core][:svec].methods, MethodStore(:svec, :Core, "built-in", 0, [:args => FakeTypeName(Vararg{Any,N} where N)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:throw].methods, MethodStore(:throw, :Core, "built-in", 0, [:e => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:tuple].methods, MethodStore(:tuple, :Core, "built-in", 0, [:args => FakeTypeName(Vararg{Any,N} where N)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:typeassert].methods, MethodStore(:typeassert, :Core, "built-in", 0, [:x => FakeTypeName(Any), :T => FakeTypeName(Type)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:typeof].methods, MethodStore(:typeof, :Core, "built-in", 0, [:x => FakeTypeName(Any)], Symbol[], FakeTypeName(Type)))

    push!(cache[:Core][:getproperty].methods, MethodStore(:getproperty, :Core, "built-in", 0, [:value => FakeTypeName(Any), :name => FakeTypeName(Symbol)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:setproperty!].methods, MethodStore(:setproperty!, :Core, "built-in", 0, [:value => FakeTypeName(Any), :name => FakeTypeName(Symbol), :x => FakeTypeName(Any)], Symbol[],FakeTypeName(Any)))

    cache[:Core][:ccall] = FunctionStore(VarRef(VarRef(Core), :ccall),
        MethodStore[
            MethodStore(:ccall, :Core, "built-in", 0, [:args => FakeTypeName(Vararg{Any,N} where N)], Symbol[], FakeTypeName(Any)) # General method - should be fixed
        ],
        "`ccall((function_name, library), returntype, (argtype1, ...), argvalue1, ...)`\n`ccall(function_name, returntype, (argtype1, ...), argvalue1, ...)`\n`ccall(function_pointer, returntype, (argtype1, ...), argvalue1, ...)`\n\nCall a function in a C-exported shared library, specified by the tuple (`function_name`, `library`), where each component is either a string or symbol. Instead of specifying a library, one\ncan also use a `function_name` symbol or string, which is resolved in the current process. Alternatively, `ccall` may also be used to call a function pointer `function_pointer`, such as one\nreturned by `dlsym`.\n\nNote that the argument type tuple must be a literal tuple, and not a tuple-valued variable or expression.\n\nEach `argvalue` to the `ccall` will be converted to the corresponding `argtype`, by automatic insertion of calls to `unsafe_convert(argtype, cconvert(argtype, argvalue))`. (See also the documentation for `unsafe_convert` and `cconvert` for further details.) In most cases, this simply results in a call to `convert(argtype, argvalue)`.", 
        VarRef(VarRef(Core), :ccall), 
        true)
    cache[:Core][Symbol("@__doc__")] = FunctionStore(VarRef(VarRef(Core), Symbol("@__doc__")), cache_methods(getfield(Core, Symbol("@__doc__"))), "", VarRef(VarRef(Core), Symbol("@__doc__")), true)
    # Accounts for the dd situation where Base.rand only has methods from Random which doesn't appear to be explicitly used.
    append!(cache[:Base][:rand].methods, cache_methods(Base.rand, Base.loaded_modules[Base.PkgId(UUID("9a3f8284-a2c9-5f02-9a11-845980a1fd5c"), "Random")]))
    return cache
end


function collect_extended_methods(depot::EnvStore, extendeds = Dict{VarRef,Vector{VarRef}}())
    for m in depot
        collect_extended_methods(m[2], extendeds, m[2].name)
    end
    extendeds
end

function collect_extended_methods(mod::ModuleStore, extendeds, mname)
    for (n,v) in mod.vals
        if (v isa FunctionStore) && v.extends != v.name
            haskey(extendeds, v.extends) ? push!(extendeds[v.extends], mname) : (extendeds[v.extends] = VarRef[v.extends.parent, mname])
        elseif v isa ModuleStore
            collect_extended_methods(v, extendeds, v.name)
        end
    end
end