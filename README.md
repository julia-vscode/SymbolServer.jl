# SymbolServer

[![Project Status: WIP – Initial development is in progress, but there has not yet been a stable, usable release suitable for the public.](https://www.repostatus.org/badges/latest/wip.svg)](https://www.repostatus.org/#wip)
[![Build Status](https://travis-ci.org/JuliaEditorSupport/SymbolServer.jl.svg?branch=master)](https://travis-ci.org/JuliaEditorSupport/SymbolServer.jl)
[![codecov.io](http://codecov.io/github/JuliaEditorSupport/SymbolServer.jl/coverage.svg?branch=master)](http://codecov.io/github/JuliaEditorSupport/SymbolServer.jl?branch=master)

SymbolServer is a helper package for LanguageServer.jl.

## Overview

You can start a new symbol server for a given julia environment like this:

````julia
using SymbolServer

path_to_julia_env = "/foo/bar"

s = SymbolServer.SymbolServerProcess(path_to_julia_env)
````

You can also start a symbol server for the default julia environment if you don't pass any path:

````julia
using SymbolServer

s = SymbolServer.SymbolServerProcess()
````

You can then call a number of functions that extract information about packages and other information for that environment.

``get_packages_in_env`` returns all the packages in that environment:

````julia
pkgs = get_packages_in_env(s)
````

``import_module`` loads a given package into the symbol server process and returns a structure with information about the symbols in that module:

````julia
mod_info = import_module(s, :MyPackage)
````

``get_doc`` should return doc information for a given symbol (but seems broken right now).

Once you are done with a given symbol server, you need to kill it with ``kill(s)`` to free the resources associated with that symbol server.
