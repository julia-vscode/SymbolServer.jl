using SymbolServer, Pkg
using SymbolServer: packagename, packageuuid, deps, manifest, project, version, Package, frommanifest
using Base:UUID
using Test

@testset "SymbolServer" begin
    server = SymbolServerProcess()

    @test server isa SymbolServerProcess
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
        depot = Dict{UUID,Package}()
        ss_m = SymbolServer.cache_package(server.context, uuid, depot)
        @test any(p->p[2].name == "SymbolServer", depot)
        @test any(p->p[2].name == "Pkg", depot)
        @test any(p->p[2].name == "SHA", depot)
    end

    @testset "Cache package on server side" begin
        uuid = packageuuid(server.context, "SHA")
        SymbolServer.cache_package(server, uuid)
        SymbolServer.update(server)
        @test "SHA" in keys(server.depot)
    end

    @testset "Load manifest packages" begin
        SymbolServer.load_manifest_packages(server)
        kill(server)
    end

    @testset "Load project packages" begin
        server = SymbolServerProcess()
        SymbolServer.load_project_packages(server)
        @test all(k in keys(server.depot) for k in ("LibGit2", "Pkg", "SHA", "Serialization"))
        kill(server)
    end
end
