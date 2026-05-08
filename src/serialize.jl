module CacheStore
using ..SymbolServer: VarRef, FakeTypeName, FakeTypeofBottom, FakeTypeVar, FakeUnion, FakeUnionAll
using ..SymbolServer: ModuleStore, Package, FunctionStore, MethodStore, DataTypeStore, GenericStore
@static if !(Vararg isa Type)
    using ..SymbolServer: FakeTypeofVararg
end

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
const FakeTypeofVarargHeader = 0x15
const UndefHeader = 0x16

struct CacheCorruptedError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CacheCorruptedError) = print(io, "CacheCorruptedError: ", e.msg)

function _check_len(io, n)
    n < 0 && throw(CacheCorruptedError("negative length: $n"))
    rem = bytesavailable(io)
    n > rem && throw(CacheCorruptedError("length $n exceeds remaining $rem bytes"))
    return n
end

const MAX_DEPTH = 256

function write(io, x)
    _write(io, x, 0)
end

function _write(io, x::VarRef, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, VarRefHeader)
    _write(io, x.parent, depth + 1)
    _write(io, x.name, depth + 1)
end
function _write(io, x::Nothing, depth::Int)
    Base.write(io, NothingHeader)
end
function _write(io, x::Char, depth::Int)
    Base.write(io, CharHeader)
    Base.write(io, UInt32(x))
end
function _write(io, x::Bool, depth::Int)
    x ? Base.write(io, TrueHeader) : Base.write(io, FalseHeader)
end
function _write(io, x::Int, depth::Int)
    Base.write(io, IntegerHeader)
    Base.write(io, x)
end
function _write(io, x::Symbol, depth::Int)
    Base.write(io, SymbolHeader)
    Base.write(io, sizeof(x))
    Base.write(io, String(x))
end
function _write(io, x::NTuple{N,Any}, depth::Int) where N
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, TupleHeader)
    Base.write(io, N)
    for i = 1:N
        _write(io, x[i], depth + 1)
    end
end
function _write(io, x::String, depth::Int)
    Base.write(io, StringHeader)
    Base.write(io, sizeof(x))
    Base.write(io, x)
end
function _write(io, x::FakeTypeName, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, FakeTypeNameHeader)
    _write(io, x.name, depth + 1)
    _write_vector(io, x.parameters, depth + 1)
end
_write(io, x::FakeTypeofBottom, depth::Int) = Base.write(io, FakeTypeofBottomHeader)
function _write(io, x::FakeTypeVar, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, FakeTypeVarHeader)
    _write(io, x.name, depth + 1)
    _write(io, x.lb, depth + 1)
    _write(io, x.ub, depth + 1)
end
function _write(io, x::FakeUnion, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, FakeUnionHeader)
    _write(io, x.a, depth + 1)
    _write(io, x.b, depth + 1)
end
function _write(io, x::FakeUnionAll, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, FakeUnionAllHeader)
    _write(io, x.var, depth + 1)
    _write(io, x.body, depth + 1)
end

@static if !(Vararg isa Type)
    function _write(io, x::FakeTypeofVararg, depth::Int)
        depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
        Base.write(io, FakeTypeofVarargHeader)
        isdefined(x, :T) ? _write(io, x.T, depth + 1) : Base.write(io, UndefHeader)
        isdefined(x, :N) ? _write(io, x.N, depth + 1) : Base.write(io, UndefHeader)
    end
end

function _write(io, x::MethodStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, MethodStoreHeader)
    _write(io, x.name, depth + 1)
    _write(io, x.mod, depth + 1)
    _write(io, x.file, depth + 1)
    Base.write(io, x.line)
    Base.write(io, length(x.sig))
    for p in x.sig
        _write(io, p[1], depth + 1)
        _write(io, p[2], depth + 1)
    end
    _write_vector(io, x.kws, depth + 1)
    _write(io, x.rt, depth + 1)
end

function _write(io, x::FunctionStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, FunctionStoreHeader)
    _write(io, x.name, depth + 1)
    _write_vector(io, x.methods, depth + 1)
    _write(io, x.doc, depth + 1)
    _write(io, x.extends, depth + 1)
    _write(io, x.exported, depth + 1)
end

function _write(io, x::DataTypeStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, DataTypeStoreHeader)
    _write(io, x.name, depth + 1)
    _write(io, x.super, depth + 1)
    _write_vector(io, x.parameters, depth + 1)
    _write_vector(io, x.types, depth + 1)
    _write_vector(io, x.fieldnames, depth + 1)
    _write_vector(io, x.methods, depth + 1)
    _write(io, x.doc, depth + 1)
    _write(io, x.exported, depth + 1)
end

function _write(io, x::GenericStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, GenericStoreHeader)
    _write(io, x.name, depth + 1)
    _write(io, x.typ, depth + 1)
    _write(io, x.doc, depth + 1)
    _write(io, x.exported, depth + 1)
end

function _write(io, x::ModuleStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, ModuleStoreHeader)
    _write(io, x.name, depth + 1)
    Base.write(io, length(x.vals))
    for p in x.vals
        _write(io, p[1], depth + 1)
        _write(io, p[2], depth + 1)
    end
    _write(io, x.doc, depth + 1)
    _write(io, x.exported, depth + 1)
    _write_vector(io, x.exportednames, depth + 1)
    _write_vector(io, x.used_modules, depth + 1)
end

function _write(io, x::Package, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, PackageHeader)
    _write(io, x.name, depth + 1)
    _write(io, x.val, depth + 1)
    Base.write(io, UInt128(x.uuid))
    Base.write(io, x.sha === nothing ? zeros(UInt8, 32) : x.sha)
end

function _write_vector(io, x, depth::Int)
    Base.write(io, length(x))
    for p in x
        _write(io, p, depth + 1)
    end
end

function read(io)
    try
        return _read(io)
    catch err
        if err isa EOFError
            throw(CacheCorruptedError("unexpected end of stream"))
        end
        rethrow()
    end
end

function _read(io, t = Base.read(io, UInt8), depth::Int = 0)
    # There are a bunch of `yield`s in potentially expensive code paths.
    # One top-level `yield` would probably increase responsiveness in the
    # LS, but increases runtime by 3x. This seems like a good compromise.
    depth > MAX_DEPTH && throw(CacheCorruptedError("depth limit exceeded ($MAX_DEPTH)"))

    if t === VarRefHeader
        VarRef(_read(io, Base.read(io, UInt8), depth + 1), _read(io, Base.read(io, UInt8), depth + 1))
    elseif t === NothingHeader
        nothing
    elseif t === SymbolHeader
        n = Base.read(io, Int)
        _check_len(io, n)
        out = Vector{UInt8}(undef, n)
        read!(io, out)
        Symbol(String(out))
    elseif t === StringHeader
        yield()
        n = Base.read(io, Int)
        _check_len(io, n)
        out = Vector{UInt8}(undef, n)
        read!(io, out)
        String(out)
    elseif t === CharHeader
        Char(Base.read(io, UInt32))
    elseif t === IntegerHeader
        Base.read(io, Int)
    elseif t === FakeTypeNameHeader
        FakeTypeName(_read(io, Base.read(io, UInt8), depth + 1), _read_vector(io, Any, depth + 1))
    elseif t === FakeTypeofBottomHeader
        FakeTypeofBottom()
    elseif t === FakeTypeVarHeader
        FakeTypeVar(_read(io, Base.read(io, UInt8), depth + 1), _read(io, Base.read(io, UInt8), depth + 1), _read(io, Base.read(io, UInt8), depth + 1))
    elseif t === FakeUnionHeader
        FakeUnion(_read(io, Base.read(io, UInt8), depth + 1), _read(io, Base.read(io, UInt8), depth + 1))
    elseif t === FakeUnionAllHeader
        FakeUnionAll(_read(io, Base.read(io, UInt8), depth + 1), _read(io, Base.read(io, UInt8), depth + 1))
    elseif t === FakeTypeofVarargHeader
        T, N = _read(io, Base.read(io, UInt8), depth + 1), _read(io, Base.read(io, UInt8), depth + 1)
        if T === nothing
            FakeTypeofVararg()
        elseif N === nothing
            FakeTypeofVararg(T)
        else
            FakeTypeofVararg(T, N)
        end
    elseif t === UndefHeader
        nothing
    elseif t === MethodStoreHeader
        yield()
        name = _read(io, Base.read(io, UInt8), depth + 1)
        mod = _read(io, Base.read(io, UInt8), depth + 1)
        file = _read(io, Base.read(io, UInt8), depth + 1)
        line = Base.read(io, UInt32)
        nsig = Base.read(io, Int)
        _check_len(io, nsig)
        sig = Vector{Pair{Any, Any}}(undef, nsig)
        for i in 1:nsig
            sig[i] = _read(io, Base.read(io, UInt8), depth + 1) => _read(io, Base.read(io, UInt8), depth + 1)
        end
        kws = _read_vector(io, Symbol, depth + 1)
        rt = _read(io, Base.read(io, UInt8), depth + 1)
        MethodStore(name, mod, file, line, sig, kws, rt)
    elseif t === FunctionStoreHeader
        yield()
        FunctionStore(
            _read(io, Base.read(io, UInt8), depth + 1),
            _read_vector(io, MethodStore, depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
        )
    elseif t === DataTypeStoreHeader
        yield()
        DataTypeStore(
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
            _read_vector(io, Any, depth + 1),
            _read_vector(io, Any, depth + 1),
            _read_vector(io, Any, depth + 1),
            _read_vector(io, MethodStore, depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
        )
    elseif t === GenericStoreHeader
        yield()
        GenericStore(
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
        )
    elseif t === ModuleStoreHeader
        yield()
        name = _read(io, Base.read(io, UInt8), depth + 1)
        n = Base.read(io, Int)
        _check_len(io, n)
        vals = Dict{Symbol,Any}()
        sizehint!(vals, n)
        for _ = 1:n
            k = _read(io, Base.read(io, UInt8), depth + 1)
            v = _read(io, Base.read(io, UInt8), depth + 1)
            vals[k] = v
        end
        doc = _read(io, Base.read(io, UInt8), depth + 1)
        exported = _read(io, Base.read(io, UInt8), depth + 1)
        exportednames = _read_vector(io, Symbol, depth + 1)
        used_modules = _read_vector(io, Symbol, depth + 1)
        ModuleStore(name, vals, doc, exported, exportednames, used_modules)
    elseif t === TrueHeader
        true
    elseif t === FalseHeader
        false
    elseif t === TupleHeader
        N = Base.read(io, Int)
        _check_len(io, N)
        ntuple(i->_read(io, Base.read(io, UInt8), depth + 1), N)
    elseif t === PackageHeader
        yield()
        name = _read(io, Base.read(io, UInt8), depth + 1)
        val = _read(io, Base.read(io, UInt8), depth + 1)
        uuid = Base.UUID(Base.read(io, UInt128))
        sha = Base.read(io, 32)
        Package(name, val, uuid, all(x == 0x00 for x in sha) ? nothing : sha)
    else
        throw(CacheCorruptedError("unknown type tag: 0x$(string(t, base=16, pad=2))"))
    end
end

function _read_vector(io, T, depth::Int = 0)
    n = Base.read(io, Int)
    _check_len(io, n)
    v = Vector{T}(undef, n)
    for i in 1:n
        v[i] = _read(io, Base.read(io, UInt8), depth + 1)
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
