using SymbolServer, Pkg
using SymbolServer: packagename, packageuuid, deps, manifest, project, version, Package, frommanifest, allnames, VarRef, _lookup
using Base:UUID
using Test

function missingsymbols(m::Module, cache::SymbolServer.ModuleStore, env)
    an = allnames()
    notfound = Symbol[]
    notfoundhidden = Symbol[]
    for n in names(m, all = true, imported = true)
        if isdefined(m, n) && !haskey(cache.vals, n)
            push!(notfound, n)
        end
    end
    for n in an
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

@testset "SymbolServer" begin
    env = SymbolServer.getenvtree([:Base, :Core])
    SymbolServer.symbols(env)
    r = missingsymbols(Core, env[:Core], env)
    @test length.(r) == (0, 0)
    r = missingsymbols(Base, env[:Base], env)
    @test length.(r) == (0, 0)

    @testset "Builtins have appropriate methods" begin
        for n in names(Core, all = true)
            if isdefined(Core, n) && (x = getfield(Core, n)) isa Core.Builtin && haskey(SymbolServer.stdlibs[:Core], n)
                @test !isempty(SymbolServer.stdlibs[:Core][n].methods)
                @test !isempty(first(SymbolServer.stdlibs[:Core][n].methods).sig)
            end
        end
    end

    mktempdir() do path
        cp(joinpath(@__DIR__, "testenv", "Project.toml"), joinpath(path, "Project.toml"))
        cp(joinpath(@__DIR__, "testenv", "Manifest.toml"), joinpath(path, "Manifest.toml"))

        store_path = joinpath(path, "store")
        mkpath(store_path)

        jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
        run(`$jl_cmd --project=$path --startup-file=no -e 'using Pkg; Pkg.instantiate()'`)

        ssi = SymbolServerInstance("", store_path)

        @async begin
            ret_status, store = getstore(ssi, path)

            @test ret_status == :canceled
        end

        # We sleep for a second here to make sure the async task we started
        # previously gets run first
        sleep(1)

        ret_status2, store2 = getstore(ssi, path)

        if ret_status2 == :failure
            @info String(take!(store2))
        end
        @info keys(store2)
        @info readdir(store_path)

        @test ret_status2 == :success
        @test length(store2) == 6
        @test haskey(store2, :Core)
        @test haskey(store2, :Base)
        @test haskey(store2, :Base64)
        @test haskey(store2, :IteratorInterfaceExtensions)
        @test haskey(store2, :Markdown)
        @test haskey(store2, :TableTraits)

        SymbolServer.clear_disc_store(ssi)

        @test length(readdir(store_path)) == 0
    end
end
