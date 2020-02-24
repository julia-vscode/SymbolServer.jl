using SymbolServer, Pkg
using SymbolServer: packagename, packageuuid, deps, manifest, project, version, Package, frommanifest
using Base:UUID
using Test

@testset "SymbolServer" begin

    mktempdir() do path
        @show ispath(path)
        cp(joinpath(@__DIR__, "testenv", "Project.toml"), joinpath(path, "Project.toml"))
        cp(joinpath(@__DIR__, "testenv", "Manifest.toml"), joinpath(path, "Manifest.toml"))

        store_path = joinpath(path, "store")
        mkpath(store_path)

        jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
        run(`$jl_cmd --project=$path --startup-file=no -e 'using Pkg; Pkg.instantiate()'`)

        ssi = SymbolServerInstance("", store_path)

        @async begin
            # @info "Async STARTED"
            ret_status, store = getstore(ssi, path)

            # @info "Async FINISHED" ret_status

            @test ret_status == :canceled
        end

        # We yield to the other task to make sure it starts
        # sleep(2)
        yield()

        # @info "SLEEP OVER"

        ret_status2, store2 = getstore(ssi, path)

        @test ret_status2 == :success
        @test length(store2) == 6
        @test haskey(store2, "Core")
        @test haskey(store2, "Base")        
        @test haskey(store2, "Base64")
        @test haskey(store2, "IteratorInterfaceExtensions")
        @test haskey(store2, "Markdown")
        @test haskey(store2, "TableTraits")

        SymbolServer.clear_disc_store(ssi)

        @test length(readdir(store_path)) == 0
    end
end
