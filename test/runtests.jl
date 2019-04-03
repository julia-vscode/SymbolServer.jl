using SymbolServer
using Test

@testset "SymbolServer" begin
    s = SymbolServerProcess()
    @test isa(s, SymbolServerProcess)
    SymbolServer.getstore(s)
    @test haskey(s.depot, "Base")
    @test haskey(s.depot, "Core")
    @test haskey(s.depot, "SymbolServer")
end
