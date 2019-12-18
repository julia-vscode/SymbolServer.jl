using Distributed
addprocs(1)
@everywhere using SymbolServer, Pkg

using Test

@testset "SymbolServer" begin
    server = SymbolServerProcess()
    @test server.context isa Pkg.Types.Context
    SymbolServer.get_context(server)
    @test server.context isa Pkg.Types.Context
    @test "SymbolServer" in keys(deps(project(server.context)))
    @test SymbolServer.isinproject(server.context, "SymbolServer")
    @test SymbolServer.isinmanifest(server.context, "SymbolServer")

    @test all(d in keys(deps(project(server.context))) for d in ("LibGit2", "Pkg", "SHA", "Serialization"))

    uuid = packageuuid(server.context, "SymbolServer")
    @test uuid isa UUID


    pe = frommanifest(server.context, uuid)
    @test pe isa SymbolServer.PackageEntry


    @test !isempty(server.depot["Base"].vals)
    @test !isempty(server.depot["Core"].vals)

    @testset "Cache package on client side" begin
        uuid = SymbolServer.packageuuid(server.context, "SymbolServer")
        depot = Dict()
        SymbolServer.cache_package(server.context, uuid, depot)
        @test any(p->p[2].name == "Dates"           , depot)
        @test any(p->p[2].name == "Distributed"     , depot)
        @test any(p->p[2].name == "InteractiveUtils", depot)
        @test any(p->p[2].name == "LibGit2"         , depot)
        @test any(p->p[2].name == "Markdown"        , depot)
        @test any(p->p[2].name == "Pkg"             , depot)
        @test any(p->p[2].name == "Printf"          , depot)
        @test any(p->p[2].name == "REPL"            , depot)
        @test any(p->p[2].name == "Random"          , depot)
        @test any(p->p[2].name == "SHA"             , depot)
        @test any(p->p[2].name == "Serialization"   , depot)
        @test any(p->p[2].name == "Sockets"         , depot)
        @test any(p->p[2].name == "SymbolServer"    , depot)
        @test any(p->p[2].name == "UUIDs"           , depot)
        @test any(p->p[2].name == "Unicode"         , depot)
    end

    @testset "Cache package on server side" begin
        uuid = SymbolServer.packageuuid(server.context, "SymbolServer")
        r = @fetchfrom 2 SymbolServer.cache_packages_and_save(server.context, Base.UUID[uuid])
        @test r isa Vector{Base.UUID}
        @test uuid in r
        report = Dict{Base.UUID,String}()
        for uuid in r
            SymbolServer.disc_load(server.context, uuid, server.depot, report)
        end
        @test isempty(report)
    end

    @testset "Load project packages" begin
        r = SymbolServer.disc_load_project(server)
        @test isempty(r)
    end
end
