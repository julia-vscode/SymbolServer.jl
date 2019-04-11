using SymbolServer, Pkg
using Test

@testset "SymbolServer" begin
    server = SymbolServerProcess()
    @test server isa SymbolServerProcess
    @test server.context isa Pkg.Types.Context
    SymbolServer.get_context(server)
    @test server.context isa Pkg.Types.Context

    pkgid = SymbolServer.PackageID("SymbolServer", string(SymbolServer.context_deps(server.context)["SymbolServer"]))
    pkgdeps = SymbolServer.pkg_deps(pkgid, server.context)
    @test all(d in keys(pkgdeps) for d in ("Pkg", "SHA", "Serialization", "Test"))
    @test SymbolServer.pkg_ver(pkgid, server.context) isa String

    depot = SymbolServer.load_core()
    @test !isempty(depot["Base"].vals)
    @test !isempty(depot["Core"].vals)

    SymbolServer.load_core(server)
    
    SymbolServer.import_package_names(pkgid, depot, server.context)
    @test any(p->p[2].name == "SymbolServer", depot)
    @test any(p->p[2].name == "Pkg", depot)
    @test any(p->p[2].name == "SHA", depot)

    SymbolServer.load_package(server, pkgid)
    
    SymbolServer.load_core(server)
    loaded_pkgs = SymbolServer.load_all(server)
    
    @test any(p->p[2] == "SymbolServer", loaded_pkgs)
    @test any(p->p[2] == "Pkg", loaded_pkgs)
    @test any(p->p[2] == "SHA", loaded_pkgs)

    SymbolServer.getstore(server)
    # @info keys(server.depot)
    # @test haskey(server.depot, "Base")
    # @test haskey(server.depot, "Core")
    # @test haskey(server.depot, "SymbolServer")
    kill(server)
end
