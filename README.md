# SymbolServer

[![Project Status: WIP – Initial development is in progress, but there has not yet been a stable, usable release suitable for the public.](https://www.repostatus.org/badges/latest/wip.svg)](https://www.repostatus.org/#wip)
[![Build Status](https://travis-ci.org/JuliaEditorSupport/SymbolServer.jl.svg?branch=master)](https://travis-ci.org/JuliaEditorSupport/SymbolServer.jl)
[![Build status](https://ci.appveyor.com/api/projects/status/cs8awj4ucfixuw4u/branch/master?svg=true)](https://ci.appveyor.com/project/davidanthoff/symbolserver-jl/branch/master)
[![codecov.io](http://codecov.io/github/JuliaEditorSupport/SymbolServer.jl/coverage.svg?branch=master)](http://codecov.io/github/JuliaEditorSupport/SymbolServer.jl?branch=master)

SymbolServer is a helper package for LanguageServer.jl.

## Overview

You can start a new symbol server for a given julia environment like this:

````julia
using SymbolServer

path_to_julia_env = "/foo/bar"

s = SymbolServerProcess(path_to_julia_env)
````

You can also start a symbol server for the default julia environment if you don't pass any path:

````julia
using SymbolServer

s = SymbolServerProcess()
````

You can then call the ``getstore`` function.
