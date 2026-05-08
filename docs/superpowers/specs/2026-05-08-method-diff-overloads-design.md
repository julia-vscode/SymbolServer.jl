# Capturing overloads via method-table diff in `indexpackage.jl`

## Problem

`scripts/packages/SymbolServer/src/indexpackage.jl` runs in a subprocess to
build the on-disk `.jstore` cache for a single package. Today it:

1. Calls `Pkg.add(...)` for the package.
2. Imports the package via `LoadingBay.eval(:(import $pkg))`.
3. Builds an environment tree restricted to the package itself:
   `env = getenvtree([current_package_name])`.
4. Runs `symbols(env, m, get_return_type=true)` which walks the names exposed
   by `m` and, for each function-valued name, calls `cache_methods` to record
   its methods.
5. Writes `env[current_package_name]` to disk as a `Package`.

The gap is in step 4: `symbols()` only iterates names that appear *inside*
the package module. If a package extends a function defined elsewhere
without bringing the name into its own module — for example
`Base.show(io::IO, ::MyType) = ...` written without
`import Base: show` — then `:show` is never iterated, `cache_methods` is
never invoked for `Base.show`, and the overload is dropped from the cache.

`server.jl` (used by full-environment `getstore`) has the *same* gap.
Although it builds `env_symbols = getenvtree()` over every loaded module,
its call site uses `visited = IdSet{Module}([Base, Core])` and
`all_names(m)` calls `unsorted_names(m, all=true, imported=false, usings=false)`
— so `Base` is never walked, and overload names brought into a user package
via `import Base.show` are not in that package's `all_names` either. Both
entry points need the same fix.

The fix is to make sure `cache_methods` is called for every function whose
method table grew while loading user packages, not just for the functions
whose names happen to appear in any walked module. The existing per-method
`_lookup(VarRef(m[1]), env)` filter then attributes each method correctly:
in `indexpackage.jl` `env` only contains the current package, so only that
package's overloads land; in `server.jl` `env` contains all user packages,
so each package's overloads land in its own modstore.

## Approach

Capture the world age before the package loads, then after loading iterate
every function-thing and call the existing `cache_methods` on any whose
method list contains at least one method with `primary_world > world_before`.
Each `Method` already carries the world age at which it was added, so an
explicit pre-load snapshot of the method table is unnecessary — a single
`UInt` is enough.

```
indexpackage.jl orchestration:
  Pkg.add(...)
  include(faketypes/symbols/utils/serialize)             # new helpers live in symbols.jl
  world_before = Base.get_world_counter()                # NEW: cheap world-age stamp
  LoadingBay.eval(:(import $current_package_name))       # package + transitive deps load here
  env = getenvtree([current_package_name])
  symbols(env, m, get_return_type=true)                  # walks the package's own names (unchanged)
  cache_new_methods!(env, world_before;
                     get_return_type=true)               # NEW: world-age filter + cache_methods on grown funcs
  modify_dirs(...) ; CacheStore.write(...)               # unchanged
```

Attribution is a property of `env`, not of new code: because `env` only
contains the current package's module tree, the `_lookup(VarRef(m[1]), env)`
filter inside `cache_methods` writes only methods defined in the package
(or its submodules). Methods added by transitively-loaded dependencies
during the import will also pass the world-age filter, but the env filter
discards them.

The world stamp is taken after `Pkg.add` and after the four `include(...)`
calls but before the package itself is imported.

## Components

### `src/symbols.jl` — new helpers

The world age field on `Method` was renamed across Julia versions: newer
Julias expose `primary_world`, older ones expose `min_world`. Pick the
correct field once at load time via a const, then read through a getter:

```julia
const _METHOD_WORLD_FIELD =
    :primary_world in fieldnames(Method) ? :primary_world : :min_world

method_world(m::Method) = getfield(m, _METHOD_WORLD_FIELD)
```

`cache_methods` gets a `min_world::UInt = UInt(0)` kwarg that skips
methods whose `method_world(m)` is `<= min_world` at the top of the
per-method loop. This is necessary for the `server.jl` call site, where
`env` may still contain `:Base` (when Base's stdlib cache is not on disk)
— without the filter, `cache_methods` would re-iterate Base's pre-existing
methods and add them to `env[:Base][:show]`. The kwarg defaults to `0`,
preserving existing call sites.

Then a single helper next to the existing `allthingswithmethods` /
`methodlist`:

```julia
# For each function with at least one method whose world age is newer than
# `world_before`, call cache_methods. The `min_world` filter inside
# cache_methods skips pre-existing methods; the existing
# `_lookup(VarRef(m[1]), env)` filter skips methods defined outside
# `env`'s module tree. Together, only newly-added methods on modules
# represented in env are written.
function cache_new_methods!(env, world_before::UInt; get_return_type = false)
    for f in allthingswithmethods()
        any(m -> method_world(m) > world_before, methodlist(f)) || continue

        name = try
            nameof(f)
        catch
            continue                          # callable types, anonymous functions — skip
        end
        cache_methods(f, name, env, get_return_type; min_world = world_before)
    end
end
```

`allthingswithmethods()` already walks every loaded module and collects
function-valued things with at least one method, so it is the natural set
to iterate. `Base.get_world_counter()` is the matching producer for the
stamps taken in `indexpackage.jl` and `server.jl`.

### `src/symbols.jl` — dedup edit inside existing `cache_methods`

The existing dedup guard at line ~267 of `symbols.jl`:

```julia
if !(m[2] in modstore[name].methods)
    push!(modstore[name].methods, m[2])
end
```

uses `===` on freshly-built `MethodStore` structs and never matches, so
re-running `cache_methods` on a function that `symbols()` already processed
would push duplicate entries. Replace with a structural equality check:

```julia
_samestore(a::MethodStore, b::MethodStore) =
    a.file == b.file && a.line == b.line && a.sig == b.sig

# ...
if !any(existing -> _samestore(existing, m[2]), modstore[name].methods)
    push!(modstore[name].methods, m[2])
end
```

`(file, line, sig)` is sufficient: two methods at the same source location
with the same signature are the same method for cache purposes.

### `src/indexpackage.jl` — orchestration

Two backward-compatible refactors are also needed so the script can be
invoked from tests against a local fixture without standing up a registry:

1. Read `store_path` from `ARGS[5]`, defaulting to `/symcache` (the Docker
   mount used by the registry indexer).
2. Skip `Pkg.add` when `Base.identify_package(name)` already returns
   non-nothing under the active project (i.e. the package was dev-deped
   into `--project` by the test harness). The Docker indexer always starts
   with an empty project, so `identify_package` returns `nothing` and the
   existing install path runs as before.

After those refactors, the orchestration becomes:

```julia
include("faketypes.jl")
include("symbols.jl")
include("utils.jl")
include("serialize.jl")
using .CacheStore

already_loadable = try
    Base.identify_package(string(current_package_name)) !== nothing
catch
    false
end
if !already_loadable
    Pkg.add(name=string(current_package_name), version=current_package_version)
end

world_before = Base.get_world_counter()

m = try
    LoadingBay.eval(:(import $current_package_name))
    getfield(LoadingBay, current_package_name)
catch e
    @info "Could not load package, exiting."
    exit(10)
end

env = getenvtree([current_package_name])
symbols(env, m, get_return_type=true)
cache_new_methods!(env, world_before; get_return_type=true)

# (existing modify_dirs + CacheStore.write follow)
```

The world stamp must be taken *before* the `LoadingBay.eval(:(import ...))`
that triggers package loading.

### `src/server.jl` — orchestration

Same shape, applied around the package-loading loop:

```julia
world_before = Base.get_world_counter()

for (i, uuid) in enumerate(packages_to_load)
    load_package(ctx, uuid, conn, LoadingBay,
                 round(Int, 100*(i - 1)/length(packages_to_load)))
end

env_symbols = getenvtree()
# (existing visited / stdlib-delete loop)
symbols(env_symbols, nothing, getallns(), visited)
cache_new_methods!(env_symbols, world_before; get_return_type=false)
# (existing wrap-as-Package + write_depot follow)
```

`env_symbols` here covers all user packages, so `cache_new_methods!`
distributes overloads across the right modstores. The `min_world` filter
prevents pollution of any stdlib entry that survived the visited/delete
pass.

## Testing

### Integration test — `getstore` / `server.jl` path

Fixture `test/testenv3/` follows the `testenv2/` layout: a `proj/`
subdirectory whose `Project.toml` + `Manifest.toml` dev-deps a sibling
package `B` (UUID `b8d7f5ca-4a81-4f4a-b8c7-1f4a0d2b3c4e`, version
`0.1.0`). The package:

- Defines `struct BType end` in its main module.
- Adds `Base.show(io::IO, ::BType) = print(io, "B")` *without* writing
  `import Base.show` — the failing case from the bug report.
- Adds `Base.show(io::IO, ::MIME"text/plain", ::BType) = print(io, "B (verbose)")`
  to confirm multi-method overloads.
- Adds `Base.length(::BType) = 0` to confirm the fix generalises beyond
  `show`.
- Defines its own `myfunc(x) = x` to confirm the existing path
  (`symbols()` walking the package's own names) still works.

The `@testitem` mirrors `testenv2`: copy fixture into a tempdir,
instantiate, run `getstore`, then open `B`'s `.jstore` and assert:

- `cached.val` (the package's `ModuleStore`) has entries `:show` and
  `:length` whose `extends` resolves to `Base.show` and `Base.length`
  respectively (i.e. `entry.extends != entry.name`).
- Each of those entries has the expected number of methods.
- `:myfunc` is still present and `extends == name` (own function, not an
  overload).

### Integration test — `indexpackage.jl` path

Same fixture, exercised as a subprocess invocation of `indexpackage.jl`
with `ARGS[5]` set to the test's `store_path`. Assertions are the same
shape as the `getstore` test, but the on-disk layout is flat
(`<store_path>/v0.1.0_nothing.jstore`) rather than nested. The script
intentionally exits 37 on success — the test asserts that.

### Unit test — in-process

A `@testitem` in `test/runtests.jl` (no subprocess) that exercises the
helper directly:

1. Defines a local struct `T` inside a fresh `Module(:_TestPkgWorldDiff)`
   (whose `parentmodule == Main`, so `VarRef(fakemod).parent === nothing`
   and the synthetic env keyed by `nameof(fakemod)` is sufficient — using
   `@__MODULE__` would require matching `@testitem`'s non-trivial parent
   chain).
2. Captures `w = Base.get_world_counter()`.
3. `eval`s `Base.length(::T) = 0` so the new method appears on
   `Base.length` with `primary_world > w`.
4. Builds a minimal `env::EnvStore` by hand whose only entry is a fresh
   `ModuleStore(VarRef(fakemod), ...)` keyed by `nameof(fakemod)`.
5. Calls `SymbolServer.cache_new_methods!(env, w; get_return_type=false)`.
6. Asserts the test module's `ModuleStore` in `env` has a `:length` entry
   with `extends` pointing to `Base.length` and exactly one method (the
   `min_world` filter would let pre-existing methods through if it were
   broken).

## Out of scope

- Changes to the on-disk cache format (`serialize.jl`) — overload entries
  use the existing `FunctionStore` shape with a non-trivial `extends`
  field.
- Changes to the language-server-side consumer — it already understands
  `extends` (see `extends_methods` / `collect_extended_methods`).
- Generalised `Base.==` on `MethodStore` — the dedup helper is private to
  `cache_methods` so it does not affect serialisation or other equality
  semantics.
