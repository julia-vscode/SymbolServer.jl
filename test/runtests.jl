using SymbolServer
using Test

@testset "SymbolServer" begin
    s = SymbolServerProcess()

    @test isa(s, SymbolServerProcess)
end
