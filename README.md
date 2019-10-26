# SymbolServer

[![Project Status: Active – The project has reached a stable, usable state and is being actively developed.](https://www.repostatus.org/badges/latest/active.svg)](https://www.repostatus.org/#active)
[![Build Status](https://travis-ci.org/julia-vscode/SymbolServer.jl.svg?branch=master)](https://travis-ci.org/julia-vscode/SymbolServer.jl)
[![Build status](https://ci.appveyor.com/api/projects/status/w8e8hru20r5f5ra2/branch/master?svg=true)](https://ci.appveyor.com/project/julia-vscode/symbolserver-jl/branch/master)
[![codecov.io](http://codecov.io/github/julia-vscode/SymbolServer.jl/coverage.svg?branch=master)](http://codecov.io/github/julia-vscode/SymbolServer.jl?branch=master)

SymbolServer is a helper package for LanguageServer.jl that provides information about internal and exported variables of packages (without loading them). A package's symbol information is initially loaded in an external process but then stored on disc for (quick loading) future use.

Documentation for working with Julia environments is available [here](https://github.com/JuliaLang/Pkg.jl).


## API

```julia
SymbolServerProcess(path_to_env)
```
Launches a server process (with given enviroment) and retrieves the active context. This client side process (this) contains a depot of retrieved packages.

```julia
change_env(ssp::SymbolServerProcess, env_path::String)
```
Activates a new environment on the server. The new active context must then be retrieved separately.

```julia
get_context(ssp::SymbolServerProcess)
```
Retrieves the active context (environment) from the server.


```julia
load_manifest_packages(ssp)
load_project_packages(ssp)
```
Load all packages from the current active environments manifest or project into the client
side depot.





