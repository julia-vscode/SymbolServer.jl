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

@testitem "method_world reads the right field" begin
    using SymbolServer: method_world

    m = first(methods(sin))
    w = method_world(m)
    @test w isa Unsigned
    @test w > 0
    @test w < typemax(typeof(w))
end

@testitem "_samestore matches MethodStores by (file, line, sig)" begin
    using SymbolServer: _samestore, MethodStore, FakeTypeName

    sig = Pair{Any,Any}[:x => FakeTypeName(Int)]
    a = MethodStore(:foo, :Mod, "/tmp/foo.jl", Int32(10), sig, Symbol[], FakeTypeName(Any))
    b = MethodStore(:foo, :Mod, "/tmp/foo.jl", Int32(10), sig, Symbol[], FakeTypeName(Any))
    c = MethodStore(:foo, :Mod, "/tmp/foo.jl", Int32(11), sig, Symbol[], FakeTypeName(Any))
    d = MethodStore(:foo, :Mod, "/tmp/other.jl", Int32(10), sig, Symbol[], FakeTypeName(Any))
    e = MethodStore(:foo, :Mod, "/tmp/foo.jl", Int32(10),
                    Pair{Any,Any}[:x => FakeTypeName(Float64)],
                    Symbol[], FakeTypeName(Any))

    @test _samestore(a, b)
    @test !_samestore(a, c)
    @test !_samestore(a, d)
    @test !_samestore(a, e)

    f = MethodStore(:bar, :Mod, "/tmp/foo.jl", Int32(10), sig, Symbol[], FakeTypeName(Any))
    g = MethodStore(:foo, :OtherMod, "/tmp/foo.jl", Int32(10), sig, Symbol[], FakeTypeName(Any))
    @test _samestore(a, f)   # different name — same location/sig — still matches
    @test _samestore(a, g)   # different mod  — same location/sig — still matches
end

@testitem "cache_new_methods! captures overloads via world age" begin
    using SymbolServer: cache_new_methods!, EnvStore, ModuleStore, VarRef, FunctionStore

    # Fresh top-level module so its VarRef has parent === nothing,
    # which keeps the env construction below trivially correct.
    fakemod = Module(:_TestPkgWorldDiff)
    Core.eval(fakemod, :(struct T end))

    w = Base.get_world_counter()

    # Define a Base.length method in fakemod *after* the world stamp.
    Core.eval(fakemod, :(Base.length(::T) = 0))

    # Build a minimal env containing only fakemod, mirroring what
    # indexpackage.jl produces via getenvtree([current_package_name]).
    env = EnvStore()
    name = nameof(fakemod)
    env[name] = ModuleStore(VarRef(fakemod), Dict{Symbol,Any}(),
                            "", true, Symbol[], Symbol[])

    cache_new_methods!(env, w; get_return_type=false)

    @test haskey(env[name], :length)
    entry = env[name][:length]
    @test entry isa FunctionStore
    @test entry.name != entry.extends                # this is an overload
    @test entry.extends.name == :length
    @test entry.extends.parent !== nothing
    @test entry.extends.parent.name == :Base
    @test length(entry.methods) == 1                 # only fakemod's overload
end

@testitem "cache_methods min_world filter skips pre-existing methods" begin
    using SymbolServer: cache_methods, EnvStore, ModuleStore, VarRef,
                        FunctionStore, method_world

    # Env that DOES contain :Base, mimicking the server.jl case where
    # Base's stdlib cache wasn't on disk and the entry survived the
    # visited/delete pass.
    env = EnvStore()
    env[:Base] = ModuleStore(VarRef(Base), Dict{Symbol,Any}(),
                             "", true, Symbol[], Symbol[])

    # Stamp picked AFTER all current methods of `sin` have been added.
    w_after_all = maximum(method_world(m) for m in methods(sin))

    cache_methods(sin, :sin, env, false; min_world = w_after_all)

    # No method satisfies world > min_world, so nothing should have been
    # added to env[:Base][:sin].
    if haskey(env[:Base], :sin)
        @test isempty(env[:Base][:sin].methods)
    else
        @test !haskey(env[:Base], :sin)
    end
end

@testitem "testenv3 captures overloads via getstore" begin
    using Pkg
    using Base: UUID

    mktempdir() do path
        cp(joinpath(@__DIR__, "testenv3"), path; force=true)

        project_path = joinpath(path, "proj")

        store_path = joinpath(path, "store")
        mkpath(store_path)

        jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do
            run(`$jl_cmd --project=$project_path --startup-file=no -e 'using Pkg; Pkg.instantiate()'`)
        end

        ssi = SymbolServerInstance("", store_path)
        ret_status, store = getstore(ssi, project_path; download=false)

        if ret_status == :failure
            @info String(take!(store))
        end
        @test ret_status == :success
        @test haskey(store, :B)

        # Inspect the on-disk cache file directly.
        cache_path = joinpath(store_path, "B",
            "B_b8d7f5ca-4a81-4f4a-b8c7-1f4a0d2b3c4e",
            "v0.1.0_nothing.jstore")
        @test isfile(cache_path)

        cached = open(SymbolServer.CacheStore.read, cache_path)
        modstore = cached.val

        # Base.show overload — the failing case the change is meant to fix.
        @test haskey(modstore, :show)
        show_entry = modstore[:show]
        @test show_entry isa SymbolServer.FunctionStore
        @test show_entry.name != show_entry.extends
        @test show_entry.extends.name == :show
        @test show_entry.extends.parent !== nothing
        @test show_entry.extends.parent.name == :Base
        @test length(show_entry.methods) >= 2

        # Base.length overload — confirms generalisation beyond show.
        @test haskey(modstore, :length)
        length_entry = modstore[:length]
        @test length_entry isa SymbolServer.FunctionStore
        @test length_entry.name != length_entry.extends
        @test length_entry.extends.name == :length
        @test length_entry.extends.parent !== nothing
        @test length_entry.extends.parent.name == :Base
        @test length(length_entry.methods) == 1

        # Own function — confirms existing path still works and is not
        # incorrectly tagged as an overload.
        @test haskey(modstore, :myfunc)
        myfunc_entry = modstore[:myfunc]
        @test myfunc_entry isa SymbolServer.FunctionStore
        @test myfunc_entry.name == myfunc_entry.extends
        @test length(myfunc_entry.methods) == 1

        SymbolServer.clear_disc_store(ssi)
        @test length(readdir(store_path)) == 0
    end
end
