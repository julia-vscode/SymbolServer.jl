using SymbolServer, JSON
using SymbolServer: VarRef, FakeTypeName, FakeUnion, FakeTypeVar, FakeTypeofBottom, FakeUnionAll,ModuleStore, MethodStore, DataTypeStore, FunctionStore, GenericStore

JSON.lower(c::FakeTypeofBottom) = "::faketypeofbottom"
JSON.lower(c::Char) = "Char::$c"

function conv(d)
    if d isa Dict
        if length(d) == 2 && all(haskey(d, k) for k in ("name", "parent")) # VarRef
            return VarRef(conv(d["parent"]), Symbol(d["name"]))
        elseif length(d) == 2 && all(haskey(d, k) for k in ("name", "parameters")) # FakeTypeName
            return FakeTypeName(conv(d["name"]), conv.(d["parameters"]))
        elseif length(d) == 2 && all(haskey(d, k) for k in ("a", "b")) # FakeUnion
            return FakeUnion(conv(d["a"]), conv(d["b"]))
        elseif length(d) == 3 && all(haskey(d, k) for k in ("name", "lb", "ub")) # FakeTypeVar
            return FakeTypeVar(Symbol(d["name"]), conv(d["lb"]), conv(d["ub"]))
        elseif length(d) == 2 && all(haskey(d, k) for k in ("var", "body")) # FakeUnionAll
            return FakeUnionAll(conv(d["var"]), conv(d["body"]))
        elseif all(haskey(d, k) for k in ("name", "vals", "doc", "exported", "exportednames", "used_modules")) # ModuleStore
            return ModuleStore(conv(d["name"]), Dict(Symbol(k) => conv(v) for (k,v) in d["vals"]), d["doc"], d["exported"], Symbol.(d["exportednames"]), Symbol.(d["used_modules"]))
        elseif all(haskey(d, k) for k in ("name", "mod", "file", "line", "sig", "kws", "rt")) # MethodStore
            sig = Pair{Any,Any}[]
            for arg in d["sig"]
                push!(sig, Symbol(first(first(arg)))=>conv(last(first(arg))))
            end
            return MethodStore(Symbol(d["name"]), Symbol(d["mod"]), d["file"], Int32(d["line"]), sig, Symbol.(d["kws"]), conv(d["rt"]))
        elseif all(haskey(d, k) for k in ("name", "super", "parameters", "types", "fieldnames", "methods", "doc", "exported")) # DataTypeStore
            return DataTypeStore(conv(d["name"]), conv(d["super"]), conv.(d["parameters"]), conv.(d["types"]), Symbol.(d["fieldnames"]), conv.(d["methods"]), d["doc"], d["exported"])
        elseif length(d) == 5 && all(haskey(d, k) for k in ("name", "methods", "doc", "extens", "exported")) # FunctionStore
            return FunctionStore(conv(d["name"]), conv.(d["methods"]), d["doc"], conv(d["extends"]), d["exported"])
        elseif length(d) == 4 && all(haskey(d, k) for k in ("name", "typ", "doc", "exported")) # GenericStore
            return GenericStore(conv(d["name"]), conv(d["typ"]), d["doc"], d["exported"])
        end
    elseif d isa String && d == "::faketypeofbottom"
        return FakeTypeofBottom()
    elseif d isa String && startswith(d,"Char::")
        return d[7]
    elseif d === nothing
        return d
    elseif d isa Number
        return d
    else
        return d
    end
end



