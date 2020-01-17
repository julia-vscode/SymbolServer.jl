# SymbolServer

[![Project Status: Active – The project has reached a stable, usable state and is being actively developed.](https://www.repostatus.org/badges/latest/active.svg)](https://www.repostatus.org/#active)
![](https://github.com/julia-vscode/SymbolServer.jl/workflows/Run%20CI%20on%20master/badge.svg)
[![codecov.io](http://codecov.io/github/julia-vscode/SymbolServer.jl/coverage.svg?branch=master)](http://codecov.io/github/julia-vscode/SymbolServer.jl?branch=master)

SymbolServer is a helper package for LanguageServer.jl that provides information about internal and exported variables of packages (without loading them). A package's symbol information is initially loaded in an external process but then stored on disc for (quick loading) future use.

Documentation for working with Julia environments is available [here](https://github.com/JuliaLang/Pkg.jl).


## API

```julia
SymbolServerInstance(path_to_depot)
```

Creates a new symbol server instance that works on a given Julia depot. This symbol server instance can be long lived, i.e. one can re-use it for different environments etc.


```julia
getstore(ssi::SymbolServerInstance, environment_path::AbstractString, result_channel)
```

Initiates async loading of symbols for the environment in `environment_path`. This function is non blocking, i.e. it returns immediately before the actual work is finished. `result_channel` must be a `Channel`. The new store, once loaded, will be pushed to that channel. One can call this function repeatedly, even before a previous call has returned results. In that case, the previous load attemp is canceled.
