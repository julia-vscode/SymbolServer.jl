# SymbolServer

[![Project Status: Active – The project has reached a stable, usable state and is being actively developed.](https://www.repostatus.org/badges/latest/active.svg)](https://www.repostatus.org/#active)
![](https://github.com/julia-vscode/SymbolServer.jl/workflows/Run%20CI%20on%20master/badge.svg)
[![codecov.io](http://codecov.io/github/julia-vscode/SymbolServer.jl/coverage.svg?branch=master)](http://codecov.io/github/julia-vscode/SymbolServer.jl?branch=master)

SymbolServer is a helper package for LanguageServer.jl that provides information about internal and exported variables of packages (without loading them). A `SymbolServerProcess` is intened to run either in the main or a parallel process (in which case the package must be loaded using `@everywhere using SymbolServer`).

Documentation for working with Julia environments is available [here](https://github.com/JuliaLang/Pkg.jl).


## API

```julia
SymbolServerProcess(c = Pkg.Types.Context())
```
Launches a server process (with given `Context`). 

```julia
disc_load(context, uuid/name, depot = Dict(), report = [])
```
Attemps to load a package (by uuid or name) from `SymbolServer`'s disc store into `depot::Dict` . A report `Dict` is returned alongside the depot indicating packages (listed by UUID) that could not be loaded.


```julia
disc_load_project(ssp)
```
Load from the disc store all packages in the active environments project. 

```julia
clear_disc_store()
```
Clear SymbolServer's disc store.



