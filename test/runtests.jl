using SymbolServer, Pkg
using SymbolServer: packagename, packageuuid, deps, manifest, project, version, Package, frommanifest, VarRef, _lookup
using Base: UUID
using Test

allns = SymbolServer.getallns()
function missingsymbols(m::Module, cache::SymbolServer.ModuleStore, env)
    notfound = Symbol[]
    notfoundhidden = Symbol[]
    for n in names(m, all=true)
        if isdefined(m, n) && !haskey(cache.vals, n)
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
                    if submod isa SymbolServer.ModuleStore && n in submod.exportednames
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

# Check that we don't have any VarRefs that point to themselves or to nothing.
function check_varrefs(env, m=nothing)
    if m === nothing
        for m in values(env)
            check_varrefs(env, m)
        end
    else
        for x in values(m.vals)
            if x isa SymbolServer.VarRef && x.parent !== nothing
                x0 = SymbolServer._lookup(x.parent, env, true)

                if x0 === nothing && x.parent !== nothing && x.parent.name === :Pidfile
                    # these are dynamically put into Base when loading FileWatching, so we
                    # don't need to error out when not finding them from the root env
                    continue
                end

                @test x0 !== nothing
                @test x0 !== m
            elseif x isa SymbolServer.ModuleStore
                check_varrefs(env, x)
            end
        end
    end
end

@testset "SymbolServer" begin
    env = SymbolServer.getenvtree([:Base, :Core])
    SymbolServer.symbols(env)
    r = missingsymbols(Core, env[:Core], env)
    @test length.(r) == (0, 0)
    r = missingsymbols(Base, env[:Base], env)
    @test length.(r) == (0, 0)
    @testset "VarRef loops" begin
        check_varrefs(env)
    end

    @testset "Builtins have appropriate methods" begin
        for n in names(Core, all=true)
            if isdefined(Core, n) && (x = getfield(Core, n)) isa Core.Builtin && haskey(SymbolServer.stdlibs[:Core], n)
                @test !isempty(SymbolServer.stdlibs[:Core][n].methods)
                @test !isempty(first(SymbolServer.stdlibs[:Core][n].methods).sig)
            end
        end
    end

    @testset "`rand` methods" begin
        @test !isempty(SymbolServer.stdlibs[:Base][:rand].methods)
    end

    @testset "check caching of UnionAlls" begin
        for n in names(Base)
            !isdefined(Base, n) && continue
            x = getfield(Base, n)
            if x isa UnionAll && Base.unwrap_unionall(x) isa DataType && parentmodule(Base.unwrap_unionall(x)) == Base
                @test SymbolServer.stdlibs[:Base][n] isa SymbolServer.DataTypeStore
            end
        end
    end

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

    @testset "issues/285" begin
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

    @test SymbolServer.stdlibs[:Base][:Sort][:sort] isa SymbolServer.FunctionStore

    @testset "symbol documentation" begin
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

    if VERSION >= v"1.1-"
        @testset "Excluding private packages from cache download requests" begin
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
    end
end

using SymbolServer: FakeTypeName

@testset "TypeofVararg" begin
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

import UUIDs
@testset "Pipe names" begin
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

@testset "Intrinsics`" begin
    @test !isempty(SymbolServer.stdlibs[:Core][:Intrinsics].vals[:llvmcall].methods)
end
