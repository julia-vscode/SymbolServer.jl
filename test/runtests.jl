using TestItemRunner

@run_package_tests

# Shared test module: computes expensive env + allns once per test process.
# Used by testitems that need the fully-populated Core/Base symbol environment.
@testmodule EnvSetup begin
    using SymbolServer
    env = SymbolServer.getenvtree([:Base, :Core])
    SymbolServer.symbols(env)
    allns = SymbolServer.getallns()
end

@testitem "Core and Base symbol completeness" setup=[EnvSetup] begin
    using SymbolServer: VarRef, _lookup, ModuleStore

    env = EnvSetup.env
    allns = EnvSetup.allns

    function missingsymbols(m::Module, cache::SymbolServer.ModuleStore, env; excludecore = false)
        notfound = Symbol[]
        notfoundhidden = Symbol[]
        for n in names(m, all=true)
            if isdefined(m, n) && !haskey(cache.vals, n)
                if excludecore && isdefined(Core, n)
                    continue
                end
                push!(notfound, n)
            end
        end
        for n in allns
            if isdefined(m, n) && !haskey(cache, n)
                found = false
                for u in cache.used_modules
                    if (submod = get(cache.vals, u, nothing)) !== nothing
                        # m has used a submodule
                        submod = submod isa VarRef ? _lookup(submod, env) : submod
                        if submod isa ModuleStore && n in submod.exportednames
                            found = true
                            break
                        end
                    end
                    if haskey(env, u) && haskey(env[u].vals, n)
                        # m has used a toplevel module
                        found = true
                        break
                    end
                end
                !found && !(n in notfound) && push!(notfoundhidden, n)
            end
        end
        notfound, notfoundhidden
    end

    r = missingsymbols(Core, env[:Core], env)
    @test length.(r) == (0, 0)

    if VERSION >= v"1.12-"
        # on 1.12, names() includes bindings from Core in Base even not requested,
        # so we filter those out here
        r = missingsymbols(Base, env[:Base], env; excludecore = true)
        @test length.(r) == (0, 0)
    else
        r = missingsymbols(Base, env[:Base], env)
        @test length.(r) == (0, 0)
    end
end

@testitem "VarRef loops" setup=[EnvSetup] begin
    using SymbolServer: VarRef, _lookup, ModuleStore

    env = EnvSetup.env

    # Check that we don't have any VarRefs that point to themselves or to nothing.
    function check_varrefs(env, m=nothing)
        if m === nothing
            for m in values(env)
                check_varrefs(env, m)
            end
        else
            for x in values(m.vals)
                if x isa VarRef && x.parent !== nothing
                    x0 = _lookup(x.parent, env, true)

                    if x0 === nothing && x.parent !== nothing && x.parent.name === :Pidfile
                        # these are dynamically put into Base when loading FileWatching, so we
                        # don't need to error out when not finding them from the root env
                        continue
                    end

                    @test x0 !== nothing
                    @test x0 !== m
                elseif x isa ModuleStore
                    check_varrefs(env, x)
                end
            end
        end
    end

    check_varrefs(env)
end

@testitem "Builtins have appropriate methods" begin
    for n in names(Core, all=true)
        if isdefined(Core, n) && (x = getfield(Core, n)) isa Core.Builtin && haskey(SymbolServer.stdlibs[:Core], n)
            @test !isempty(SymbolServer.stdlibs[:Core][n].methods)
            @test !isempty(first(SymbolServer.stdlibs[:Core][n].methods).sig)
        end
    end
end

@testitem "rand methods" begin
    @test !isempty(SymbolServer.stdlibs[:Base][:rand].methods)
end

@testitem "check caching of UnionAlls" begin
    for n in names(Base)
        !isdefined(Base, n) && continue
        x = getfield(Base, n)
        if x isa UnionAll && Base.unwrap_unionall(x) isa DataType && parentmodule(Base.unwrap_unionall(x)) == Base
            @test SymbolServer.stdlibs[:Base][n] isa SymbolServer.DataTypeStore
        end
    end
end

@testitem "testenv integration" begin
    using Pkg

    mktempdir() do path
        cp(joinpath(@__DIR__, "testenv"), path; force=true)

        store_path = joinpath(path, "store")
        mkpath(store_path)

        jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do
            run(`$jl_cmd --project=$path --startup-file=no -e 'using Pkg; Pkg.instantiate()'`)
        end

        ssi = SymbolServerInstance("", store_path)

        @async begin
            ret_status, store = getstore(ssi, path, download = false)

            @test ret_status == :canceled
        end

        # We sleep for a second here to make sure the async task we started
        # previously gets started first
        sleep(1)

        # this will cancel the previous getstore request
        ret_status2, store2 = getstore(ssi, path, download = false)

        if ret_status2 == :failure
            @info String(take!(store2))
        end

        @test ret_status2 == :success
        @test length(store2) == 7
        @test haskey(store2, :Core)
        @test haskey(store2, :Base)
        @test haskey(store2, :Main)
        @test haskey(store2, :Base64)
        @test haskey(store2, :IteratorInterfaceExtensions)
        @test haskey(store2, :Markdown)
        @test haskey(store2, :TableTraits)

        SymbolServer.clear_disc_store(ssi)

        @test length(readdir(store_path)) == 0
    end
end

@testitem "issues/285 testenv2" begin
    VERSION < v"1.6" && return

    using Pkg

    mktempdir() do path
        cp(joinpath(@__DIR__, "testenv2"), path; force=true)

        project_path = joinpath(path, "proj")

        store_path = joinpath(path, "store")
        mkpath(store_path)

        jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do
            run(`$jl_cmd --project=$project_path --startup-file=no -e 'using Pkg; Pkg.instantiate()'`)
        end

        ssi = SymbolServerInstance("", store_path)
        ret_status, store = getstore(ssi, project_path; download=false)
        @test ret_status == :success
        @test length(store) == 4
        @test haskey(store, :Core)
        @test haskey(store, :Base)
        @test haskey(store, :Main)
        @test haskey(store, :A)

        # Inspect the cached version, and check that the package SHA has been computed
        # correctly.
        cache_path = joinpath(store_path, "A", "A_94f385dd-073b-49fe-b7ed-f824d09b3331", "v0.1.0_nothing.jstore")
        @test isfile(cache_path)

        cached_version = open(SymbolServer.CacheStore.read, cache_path)
        @test !isnothing(cached_version.sha)
        @test cached_version.sha == SymbolServer.sha2_256_dir(joinpath(path, "A", "src"))

        SymbolServer.clear_disc_store(ssi)
        @test length(readdir(store_path)) == 0
    end
end

@testitem "Sort submodule access" begin
    @test SymbolServer.stdlibs[:Base][:Sort][:sort] isa SymbolServer.FunctionStore
end

@testitem "symbol documentation" begin
    @test !isempty(SymbolServer.stdlibs[:Base][:abs].doc)          # Function
    if VERSION >= v"1.7"
        @test !isempty(SymbolServer.stdlibs[:Core][:Pair].doc)         # DataType
    else
        @test !isempty(SymbolServer.stdlibs[:Base][:Pair].doc)         # DataType
    end
    @test !isempty(SymbolServer.stdlibs[:Base][:Libc].doc)         # Module
    @test !isempty(SymbolServer.stdlibs[:Base][:LinRange].doc)     # UnionAll
    @test !isempty(SymbolServer.stdlibs[:Base][:VecOrMat].doc)     # Union
    @test occursin("Cint", SymbolServer.stdlibs[:Base][:Cint].doc) # Alias
end

@testitem "Excluding private packages from cache download" begin
    VERSION < v"1.1-" && return

    using Pkg
    using Base: UUID

    pkgs = Dict{Base.UUID,Pkg.Types.PackageEntry}()
    if VERSION < v"1.3-"
        pkgs[UUID("7876af07-990d-54b4-ab0e-23690620f79a")] = Pkg.Types.PackageEntry(name="Example", other=Dict("git-tree-sha1" => Base.SHA1("0"^40)))
        pkgs[UUID("3e13f8c9-a9aa-412e-8b2a-fda000b375e2")] = Pkg.Types.PackageEntry(name="NotInGeneral", other=Dict("git-tree-sha1" => Base.SHA1("0"^40)))
        pkgs[UUID("eb4ab7d2-1172-48bd-a954-ae6825f2e6e3")] = Pkg.Types.PackageEntry(other=Dict("git-tree-sha1" => Base.SHA1("0"^40))) # no name
        pkgs[UUID("1fec9e91-426f-45f4-a317-da8b2730f864")] = Pkg.Types.PackageEntry(name="NoTreeHash") # no tree_hash, like stdlibs
    else
        pkgs[UUID("7876af07-990d-54b4-ab0e-23690620f79a")] = Pkg.Types.PackageEntry(name="Example", tree_hash=Base.SHA1("0"^40))
        pkgs[UUID("3e13f8c9-a9aa-412e-8b2a-fda000b375e2")] = Pkg.Types.PackageEntry(name="NotInGeneral", tree_hash=Base.SHA1("1"^40))
        pkgs[UUID("eb4ab7d2-1172-48bd-a954-ae6825f2e6e3")] = Pkg.Types.PackageEntry(tree_hash=Base.SHA1("2"^40)) # no name
        pkgs[UUID("1fec9e91-426f-45f4-a317-da8b2730f864")] = Pkg.Types.PackageEntry(name="NoTreeHash") # no tree_hash, like stdlibs
    end

    SymbolServer.remove_non_general_pkgs!(pkgs)

    @test length(pkgs) == 1
    @test haskey(pkgs, UUID("7876af07-990d-54b4-ab0e-23690620f79a"))
    @test pkgs[UUID("7876af07-990d-54b4-ab0e-23690620f79a")].name == "Example"
    if VERSION < v"1.3"
        @test pkgs[UUID("7876af07-990d-54b4-ab0e-23690620f79a")].other["git-tree-sha1"] == Base.SHA1("0"^40)
    else
        @test pkgs[UUID("7876af07-990d-54b4-ab0e-23690620f79a")].tree_hash == Base.SHA1("0"^40)
    end
end

@testitem "TypeofVararg" begin
    using SymbolServer: FakeTypeName

    Ts = Any[Vararg, Vararg{Bool,3}, NTuple{N,Any} where {N}]
    isdefined(Core, :TypeofVararg) && append!(Ts, Any[Vararg{Int}, Vararg{Rational}])

    for ((i, T1), (j, T2)) in Iterators.product(enumerate.((Ts, Ts))...)
        if i == j
            @test FakeTypeName(T1) == FakeTypeName(T2)
        else
            @test FakeTypeName(T1) != FakeTypeName(T2)
        end
    end

    for T in Ts
        @test eval(Meta.parse(string(FakeTypeName(T)))) == T
    end
end

@testitem "Pipe names" begin
    import UUIDs

    if Sys.iswindows()
        p = SymbolServer.pipe_name()
        @test occursin(r"^\\\\\.\\pipe\\vscjlsymserv-\w{8}-(?:\w{4}-?){3}\w{12}$", p)
    else
        tmp_access = try
            n = "/tmp/" * string(UUIDs.uuid4())
            touch(n)
            rm(n)
            true
        catch
            false
        end
        too_long = joinpath(tempdir(), string(UUIDs.uuid4())^3)
        mkdir(too_long)
        for TEMPDIR in (tempdir(), too_long)
            withenv("TEMPDIR" => TEMPDIR) do
                p = SymbolServer.pipe_name()
                #         TEMPDIR    + / + prefix                  + UUID[1:13]
                if length(tempdir()) + 1 + length("vscjlsymserv-") + 13 < 92 || !tmp_access
                    @test startswith(p, tempdir())
                    @test occursin(r"^vscjlsymserv-\w{8}-\w{4}$", basename(p))
                else
                    @test occursin(r"^/tmp/vscjlsymserv-\w{8}(?:-\w{4}){3}-\w{12}$", p)
                end
            end
        end
        rm(too_long; recursive=true)
    end
end

@testitem "Intrinsics" begin
    @test !isempty(SymbolServer.stdlibs[:Core][:Intrinsics].vals[:llvmcall].methods)
end

@testitem "CacheStore rejects unknown header" begin
    using SymbolServer.CacheStore: CacheCorruptedError, read

    io = IOBuffer(UInt8[0xff])
    @test_throws CacheCorruptedError read(io)
end

@testitem "CacheStore rejects truncated stream" begin
    using SymbolServer.CacheStore: CacheCorruptedError, read

    # SymbolHeader (0x02) + length=100, but only 5 payload bytes
    io = IOBuffer(vcat(UInt8[0x02], reinterpret(UInt8, [Int(100)]), UInt8[0x41, 0x41, 0x41, 0x41, 0x41]))
    @test_throws CacheCorruptedError read(io)

    # Empty stream
    @test_throws CacheCorruptedError read(IOBuffer(UInt8[]))

    # Header byte present, but length field truncated
    @test_throws CacheCorruptedError read(IOBuffer(UInt8[0x02, 0x00, 0x00]))
end

@testitem "CacheStore rejects oversized length fields" begin
    using SymbolServer.CacheStore: CacheCorruptedError, read

    # SymbolHeader (0x02) + length=10^15 in a 9-byte stream → way over remaining bytes
    huge = Int(10)^15
    io = IOBuffer(vcat(UInt8[0x02], reinterpret(UInt8, [huge])))
    @test_throws CacheCorruptedError read(io)

    # Negative length
    io = IOBuffer(vcat(UInt8[0x02], reinterpret(UInt8, [Int(-1)])))
    @test_throws CacheCorruptedError read(io)

    # StringHeader with oversized length
    io = IOBuffer(vcat(UInt8[0x05], reinterpret(UInt8, [huge])))
    @test_throws CacheCorruptedError read(io)

    # TupleHeader (0x14) with oversized length
    io = IOBuffer(vcat(UInt8[0x14], reinterpret(UInt8, [huge])))
    @test_throws CacheCorruptedError read(io)
end

@testitem "CacheStore rejects cyclic data on write" begin
    using SymbolServer.CacheStore: write
    using SymbolServer: VarRef, FakeTypeName

    name = VarRef(nothing, :A)
    ft = FakeTypeName(name, Any[])
    push!(ft.parameters, ft)        # cycle: ft.parameters[1] === ft

    io = IOBuffer()
    @test_throws ArgumentError write(io, ft)

    # Non-cyclic but very deep also rejected
    deep = let d = FakeTypeName(name, Any[])
        for _ in 1:300
            d = FakeTypeName(name, Any[d])
        end
        d
    end
    io = IOBuffer()
    @test_throws ArgumentError write(io, deep)
end

@testitem "CacheStore rejects deeply nested input on read" begin
    using SymbolServer.CacheStore: CacheCorruptedError

    # Build a hand-crafted byte stream of nested FakeTypeName encodings.
    # Wire format per level:
    #   FakeTypeNameHeader (0x07)
    #   + VarRef encoding for name: VarRefHeader (0x06), parent=NothingHeader (0x01),
    #                               name=SymbolHeader (0x02) + Int(1) + 'a' (0x61)
    #   + parameters vector: Int(1) + nested element  (or Int(0) for innermost)
    function nested_bytes(level::Int)
        io = IOBuffer()
        # Innermost: FakeTypeName(VarRef(nothing, :a), [])
        Base.write(io, 0x07)
        Base.write(io, 0x06); Base.write(io, 0x01)
        Base.write(io, 0x02); Base.write(io, Int(1)); Base.write(io, 0x61)
        Base.write(io, Int(0))
        bytes = take!(io)

        for _ in 1:level
            io = IOBuffer()
            Base.write(io, 0x07)
            Base.write(io, 0x06); Base.write(io, 0x01)
            Base.write(io, 0x02); Base.write(io, Int(1)); Base.write(io, 0x61)
            Base.write(io, Int(1))
            Base.write(io, bytes)
            bytes = take!(io)
        end
        return bytes
    end

    # 300 levels exceeds MAX_DEPTH=256
    bytes = nested_bytes(300)
    @test_throws CacheCorruptedError SymbolServer.CacheStore.read(IOBuffer(bytes))

    # 100 levels is well under MAX_DEPTH and should succeed
    bytes = nested_bytes(100)
    SymbolServer.CacheStore.read(IOBuffer(bytes))   # no throw
end

@testitem "Corrupt cache file produces CacheCorruptedError" begin
    using SymbolServer

    mktempdir() do store_path
        pkg_dir = joinpath(store_path, "Bogus", "Bogus_00000000-0000-0000-0000-000000000000")
        mkpath(pkg_dir)
        cache_path = joinpath(pkg_dir, "v0.1.0_nothing.jstore")
        open(cache_path, "w") do io
            Base.write(io, UInt8[0xff])    # unknown header → CacheCorruptedError
        end
        @test isfile(cache_path)

        threw = false
        try
            open(SymbolServer.CacheStore.read, cache_path)
        catch err
            threw = err isa SymbolServer.CacheStore.CacheCorruptedError
        end
        @test threw
    end
end

@testitem "Length validation accepts valid lengths over IOStream buffer chunk" begin
    # Regression: bytesavailable(::IOStream) returns the buffered chunk size, not
    # remaining file bytes. A naive remaining-bytes check spuriously rejects
    # legitimate length fields when reading real cache files from disk.
    using SymbolServer.CacheStore: read

    mktemp() do path, io
        Base.write(io, 0x05)                    # StringHeader
        Base.write(io, Int(30))                 # length 30
        Base.write(io, repeat("a", 30))
        close(io)

        s = open(read, path)
        @test s == repeat("a", 30)
    end
end
