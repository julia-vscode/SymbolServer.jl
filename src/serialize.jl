module CacheStore
using SymbolServer: VarRef, FakeTypeName, FakeTypeofBottom, FakeTypeVar, FakeUnion, FakeUnionAll
using SymbolServer: ModuleStore, Package, FunctionStore, MethodStore, DataTypeStore, GenericStore

const NothingHeader = 0x01
const SymbolHeader = 0x02
const CharHeader = 0x03
const IntegerHeader = 0x04
const StringHeader = 0x05
const VarRefHeader = 0x06
const FakeTypeNameHeader = 0x07
const FakeTypeofBottomHeader = 0x08
const FakeTypeVarHeader = 0x09
const FakeUnionHeader = 0x0a
const FakeUnionAllHeader = 0xb
const ModuleStoreHeader = 0x0c
const MethodStoreHeader = 0x0d
const FunctionStoreHeader = 0x0e
const DataTypeStoreHeader = 0x0f
const GenericStoreHeader = 0x10
const PackageHeader = 0x11
const TrueHeader = 0x12
const FalseHeader = 0x13
const TupleHeader = 0x14


function write(io, x::VarRef)
    Base.write(io, VarRefHeader)
    write(io, x.parent)
    write(io, x.name)
end
function write(io, x::Nothing)
    Base.write(io, NothingHeader)
end
function write(io, x::Char)
    Base.write(io, CharHeader)
    Base.write(io, UInt32(x))
end
function write(io, x::Bool)
    x ? Base.write(io, TrueHeader) : Base.write(io, FalseHeader)
end
function write(io, x::Int)
    Base.write(io, IntegerHeader)
    Base.write(io, x)
end
function write(io, x::Symbol)
    Base.write(io, SymbolHeader)
    Base.write(io, sizeof(x))
    Base.write(io, String(x))
end
function write(io, x::String)
    Base.write(io, StringHeader)
    Base.write(io, sizeof(x))
    Base.write(io, x)
end
function write(io, x::FakeTypeName)
    Base.write(io, FakeTypeNameHeader)
    write(io, x.name)
    write_vector(io, x.parameters)
end
write(io, x::FakeTypeofBottom) = Base.write(io, FakeTypeofBottomHeader)
function write(io, x::FakeTypeVar)
    Base.write(io, FakeTypeVarHeader)
    write(io, x.name)
    write(io, x.lb)
    write(io, x.ub)
end
function write(io, x::FakeUnion)
    Base.write(io, FakeUnionHeader)
    write(io, x.a)
    write(io, x.b)
end
function write(io, x::FakeUnionAll)
    Base.write(io, FakeUnionAllHeader)
    write(io, x.var)
    write(io, x.body)
end

function write(io, x::MethodStore)
    Base.write(io, MethodStoreHeader)
    write(io, x.name)
    write(io, x.mod)
    write(io, x.file)
    Base.write(io, x.line)
    Base.write(io, length(x.sig))
    for p in x.sig
        write(io, p[1])
        write(io, p[2])
    end
    write_vector(io, x.kws)
    write(io, x.rt)
end

function write(io, x::FunctionStore)
    Base.write(io, FunctionStoreHeader)
    write(io, x.name)
    write_vector(io, x.methods)
    write(io, x.doc)
    write(io, x.extends)
    write(io, x.exported)
end

function write(io, x::DataTypeStore)
    Base.write(io, DataTypeStoreHeader)
    write(io, x.name)
    write(io, x.super)
    write_vector(io, x.parameters)
    write_vector(io, x.types)
    write_vector(io, x.fieldnames)
    write_vector(io, x.methods)
    write(io, x.doc)
    write(io, x.exported)
end

function write(io, x::GenericStore)
    Base.write(io, GenericStoreHeader)
    write(io, x.name)
    write(io, x.typ)
    write(io, x.doc)
    write(io, x.exported)
end

function write(io, x::ModuleStore)
    Base.write(io, ModuleStoreHeader)
    write(io, x.name)
    Base.write(io, length(x.vals))
    for p in x.vals
        write(io, p[1])
        write(io, p[2])
    end
    write(io, x.doc)
    write(io, x.exported)
    write_vector(io, x.exportednames)
    write_vector(io, x.used_modules)
end

# function write(io, x::Package)
#     Base.write(io, PackageHeader)
#     write(io, x.name)
#     write(io, x.val)
#     write(io, x.doc)
#     write(io, x.exported)
# end

function write_vector(io, x)
    Base.write(io, length(x))
    for p in x
        write(io, p)
    end
end

function read(io, t = Base.read(io, UInt8))
    if t === VarRefHeader
        VarRef(read(io), read(io))
    elseif t === NothingHeader
        nothing
    elseif t === SymbolHeader
        n = Base.read(io, Int)
        out = UInt8[]
        readbytes!(io, out, n)
        Symbol(String(out))
    elseif t === StringHeader
        n = Base.read(io, Int)
        out = UInt8[]
        readbytes!(io, out, n)
        String(out)
    elseif t === CharHeader
        Char(Base.read(io, UInt32))
    elseif t === IntegerHeader
        Base.read(io, Int)
    elseif t === FakeTypeNameHeader
        FakeTypeName(read(io), read_vector(io, Any))
    elseif t === FakeTypeofBottomHeader
        FakeTypeofBottom()
    elseif t === FakeTypeVarHeader
        FakeTypeVar(read(io), read(io), read(io))
    elseif t === FakeUnionHeader
        FakeUnion(read(io), read(io))
    elseif t === FakeUnionAllHeader
        FakeUnionAll(read(io), read(io))
    elseif t === MethodStoreHeader
        name = read(io)
        mod = read(io)
        file = read(io)
        line = Base.read(io, UInt32)
        nsig = Base.read(io, Int)
        sig = Any[]
        for i = 1:nsig
            push!(sig, read(io)=>read(io))
        end
        kws = read_vector(io, Symbol)
        rt = read(io)
        MethodStore(name, mod, file, line, sig, kws, rt)
    elseif t === FunctionStoreHeader
        FunctionStore(read(io), read_vector(io, MethodStore), read(io), read(io), read(io))
    elseif t === DataTypeStoreHeader
        DataTypeStore(read(io), read(io), read_vector(io, Any), read_vector(io, Any), read_vector(io, Any), read_vector(io, MethodStore), read(io), read(io))
    elseif t === GenericStoreHeader
        GenericStore(read(io), read(io), read(io), read(io))
    elseif t === ModuleStoreHeader
        name = read(io)
        n = Base.read(io, Int)
        vals = Dict{Symbol,Any}()
        for i = 1:n
            k = read(io)
            v = read(io)
            vals[k] = v
        end
        doc = read(io)
        exported = read(io)
        exportednames = read_vector(io, Symbol)
        used_modules = read_vector(io, Symbol)
        ModuleStore(name, vals, doc, exported, exportednames, used_modules)
    elseif t === TrueHeader
        true
    elseif t === FalseHeader
        false
    else
        error("HIYA")
    end
end

function read_vector(io, T)
    n = Base.read(io, Int)
    v = T[]
    # v = Array{T}(undef, n)
    for i = 1:n
        push!(v, read(io))
    end
    v
end

function storeunstore(x)
    io = IOBuffer()
    write(io, x)
    bs = take!(io)    
    read(IOBuffer(bs))
end
end