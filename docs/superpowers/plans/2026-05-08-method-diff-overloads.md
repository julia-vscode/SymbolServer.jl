# Method-Table Diff for Capturing Package Overloads — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make both `indexpackage.jl` (registry indexer path) and `server.jl` (`getstore` path) capture method overloads on functions defined outside the package — e.g. `Base.show(io, ::MyType)` written without `import Base.show` — by stamping `Base.get_world_counter()` before package loads and re-running `cache_methods` over every function with at least one method whose world is newer than the stamp.

**Architecture:** A new helper in `src/symbols.jl` (`cache_new_methods!`) drives the diff. `cache_methods` gets a `min_world` kwarg so the helper can skip pre-existing methods (necessary because `server.jl`'s `env` may contain `:Base`, where old methods would otherwise be re-added). `indexpackage.jl` is also lightly refactored so it can be invoked from tests against a local fixture (accepts `store_path` as `ARGS[5]`, skips `Pkg.add` when the package is already loadable via the active project). Two integration tests cover the two entry paths independently; one in-process unit test covers the helper.

**Tech Stack:** Julia, Pkg, TestItemRunner.

---

## File Structure

**Modify:**
- `src/symbols.jl` — add `_METHOD_WORLD_FIELD` const, `method_world(::Method)` getter, `_samestore(::MethodStore, ::MethodStore)` helper, `cache_new_methods!` function. Add `min_world::UInt = UInt(0)` kwarg to `cache_methods` and replace the dedup `in` check with `_samestore`-based `any`.
- `src/indexpackage.jl` — capture `world_before` before `LoadingBay.eval(:(import ...))`, call `cache_new_methods!` after `symbols(...)`. Refactor so `store_path` comes from `ARGS[5]` (defaulting to `/symcache`) and `Pkg.add` is skipped when the package is already loadable via the active project.
- `src/server.jl` — capture `world_before` before the package-loading loop, call `cache_new_methods!` after `symbols(...)`.
- `test/runtests.jl` — append three new `@testitem`s (unit, server.jl integration, indexpackage.jl integration).

**Create:**
- `test/testenv3/proj/Project.toml`
- `test/testenv3/proj/Manifest.toml`
- `test/testenv3/B/Project.toml`
- `test/testenv3/B/src/B.jl`

The fixture uses a fixed UUID for `B`: `b8d7f5ca-4a81-4f4a-b8c7-1f4a0d2b3c4e`. Use this exact UUID everywhere the plan calls for it.

---

### Task 1: Version-portable Method world-age getter

**Files:**
- Modify: `src/symbols.jl` (new lines, just below the existing `_default_world_age()` definition near line 165)
- Modify: `test/runtests.jl` (new testitem)

- [ ] **Step 1: Write the failing test**

Append to `test/runtests.jl`:

```julia
@testitem "method_world reads the right field" begin
    using SymbolServer: method_world

    m = first(methods(sin))
    w = method_world(m)
    @test w isa Unsigned
    @test w >= 0
    @test w < typemax(typeof(w))
end
```

- [ ] **Step 2: Run test to verify it fails**

Run from `scripts/packages/SymbolServer`:

```
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30
```

Expected: failure with `UndefVarError: method_world` for the new testitem.

- [ ] **Step 3: Implement the getter**

Add immediately below the existing `_default_world_age()` block (around line 166 of `src/symbols.jl`, before `const _global_method_cache = ...`):

```julia
const _METHOD_WORLD_FIELD =
    :primary_world in fieldnames(Method) ? :primary_world : :min_world

method_world(m::Method) = getfield(m, _METHOD_WORLD_FIELD)
```

- [ ] **Step 4: Run test to verify it passes**

```
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30
```

Expected: PASS for `method_world reads the right field`, all pre-existing tests still pass.

- [ ] **Step 5: Commit**

```
git add src/symbols.jl test/runtests.jl
git commit -m "feat(SymbolServer): add version-portable Method world-age getter"
```

---

### Task 2: Structural MethodStore dedup inside cache_methods

The existing dedup at line 267-269 of `src/symbols.jl` uses `m[2] in modstore[name].methods` which falls back to `===` on freshly-built `MethodStore` structs and never matches. Once `cache_new_methods!` (Task 3) re-runs `cache_methods` for functions `symbols()` already processed, this would push duplicate entries.

**Files:**
- Modify: `src/symbols.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing test for `_samestore`**

Append to `test/runtests.jl`:

```julia
@testitem "_samestore matches MethodStores by (file, line, sig)" begin
    using SymbolServer: _samestore, MethodStore, FakeTypeName

    sig = Pair{Any,Any}[:x => FakeTypeName(Int)]
    a = MethodStore(:foo, :Mod, "/tmp/foo.jl", Int32(10), sig, Symbol[], FakeTypeName(Any))
    b = MethodStore(:foo, :Mod, "/tmp/foo.jl", Int32(10), sig, Symbol[], FakeTypeName(Any))
    c = MethodStore(:foo, :Mod, "/tmp/foo.jl", Int32(11), sig, Symbol[], FakeTypeName(Any))
    d = MethodStore(:foo, :Mod, "/tmp/other.jl", Int32(10), sig, Symbol[], FakeTypeName(Any))
    e = MethodStore(:foo, :Mod, "/tmp/foo.jl", Int32(10),
                    Pair{Any,Any}[:x => FakeTypeName(Float64)],
                    Symbol[], FakeTypeName(Any))

    @test _samestore(a, b)
    @test !_samestore(a, c)
    @test !_samestore(a, d)
    @test !_samestore(a, e)
end
```

- [ ] **Step 2: Run test to verify it fails**

```
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30
```

Expected: failure with `UndefVarError: _samestore`.

- [ ] **Step 3: Add the `_samestore` helper**

Add directly below the `Base.show(io::IO, ms::MethodStore)` definition (around line 52 of `src/symbols.jl`, before `struct DataTypeStore`):

```julia
_samestore(a::MethodStore, b::MethodStore) =
    a.file == b.file && a.line == b.line && a.sig == b.sig
```

- [ ] **Step 4: Replace the dedup `in` check inside `cache_methods`**

In `src/symbols.jl`, locate this block (around line 267-269):

```julia
            if !(m[2] in modstore[name].methods)
                push!(modstore[name].methods, m[2])
            end
```

Replace it with:

```julia
            if !any(existing -> _samestore(existing, m[2]), modstore[name].methods)
                push!(modstore[name].methods, m[2])
            end
```

- [ ] **Step 5: Run tests**

```
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30
```

Expected: `_samestore matches MethodStores by (file, line, sig)` PASSES, all pre-existing tests still pass.

- [ ] **Step 6: Commit**

```
git add src/symbols.jl test/runtests.jl
git commit -m "feat(SymbolServer): structural MethodStore dedup in cache_methods"
```

---

### Task 3: `min_world` kwarg + `cache_new_methods!` helper

`cache_methods` needs to be able to skip methods older than a given world stamp, otherwise `cache_new_methods!` running over `server.jl`'s env (which contains `:Base`) would re-add Base's pre-existing methods to `env[:Base][:show]`.

**Files:**
- Modify: `src/symbols.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing unit test**

Append to `test/runtests.jl`:

```julia
@testitem "cache_new_methods! captures overloads via world age" begin
    using SymbolServer: cache_new_methods!, EnvStore, ModuleStore, VarRef, FunctionStore

    # Fresh top-level module so its VarRef has parent === nothing,
    # which keeps the env construction below trivially correct.
    fakemod = Module(:_TestPkgWorldDiff)
    Core.eval(fakemod, :(struct T end))

    w = Base.get_world_counter()

    # Define a Base.length method in fakemod *after* the world stamp.
    Core.eval(fakemod, :(Base.length(::T) = 0))

    # Build a minimal env containing only fakemod, mirroring what
    # indexpackage.jl produces via getenvtree([current_package_name]).
    env = EnvStore()
    name = nameof(fakemod)
    env[name] = ModuleStore(VarRef(fakemod), Dict{Symbol,Any}(),
                            "", true, Symbol[], Symbol[])

    cache_new_methods!(env, w; get_return_type=false)

    @test haskey(env[name], :length)
    entry = env[name][:length]
    @test entry isa FunctionStore
    @test entry.name != entry.extends                # this is an overload
    @test entry.extends.name == :length
    @test entry.extends.parent !== nothing
    @test entry.extends.parent.name == :Base
    @test length(entry.methods) == 1                 # only fakemod's overload
end

@testitem "cache_methods min_world filter skips pre-existing methods" begin
    using SymbolServer: cache_methods, EnvStore, ModuleStore, VarRef,
                        FunctionStore, method_world

    # Env that DOES contain :Base, mimicking the server.jl case where
    # Base's stdlib cache wasn't on disk and the entry survived the
    # visited/delete pass.
    env = EnvStore()
    env[:Base] = ModuleStore(VarRef(Base), Dict{Symbol,Any}(),
                             "", true, Symbol[], Symbol[])

    # Stamp picked AFTER all current methods of `sin` have been added.
    w_after_all = maximum(method_world(m) for m in methods(sin))

    cache_methods(sin, :sin, env, false; min_world = w_after_all)

    # No method satisfies world > min_world, so nothing should have been
    # added to env[:Base][:sin].
    if haskey(env[:Base], :sin)
        @test isempty(env[:Base][:sin].methods)
    else
        @test !haskey(env[:Base], :sin)
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

```
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30
```

Expected: failure with `UndefVarError: cache_new_methods!`.

- [ ] **Step 3: Add the `min_world` kwarg to `cache_methods`**

In `src/symbols.jl`, locate the function header (around line 195):

```julia
function cache_methods(@nospecialize(f), name, env, get_return_type)
```

Replace with:

```julia
function cache_methods(@nospecialize(f), name, env, get_return_type; min_world::UInt = UInt(0))
```

Then locate the per-method loop (around line 210) that starts with `for m in methods0` and add a skip at the top of the loop body. The current structure is:

```julia
    i = 1
    for m in methods0
        # Get inferred method return type
        if get_return_type
            ...
```

Insert the world filter as the first thing in the loop:

```julia
    i = 1
    for m in methods0
        if method_world(m[3]) <= min_world
            continue
        end
        # Get inferred method return type
        if get_return_type
            ...
```

`m[3]` is the `Method` object (per `Base._methods` triple structure already used elsewhere in the function).

- [ ] **Step 4: Implement `cache_new_methods!`**

Append to `src/symbols.jl` immediately after the `allmethods()` function (around line 378), before `usedby` / `istoplevelmodule`:

```julia
"""
    cache_new_methods!(env, world_before; get_return_type=false)

For every function-thing with at least one method whose `method_world` is
newer than `world_before`, call `cache_methods(f, name, env, get_return_type;
min_world=world_before)`. The `min_world` filter inside `cache_methods`
skips pre-existing methods, and the existing `_lookup(VarRef(m[1]), env)`
filter skips methods whose defining module is not represented in `env`.
The caller controls attribution by choosing what `env` contains.
"""
function cache_new_methods!(env, world_before::UInt; get_return_type = false)
    for f in allthingswithmethods()
        any(m -> method_world(m) > world_before, methodlist(f)) || continue

        name = try
            nameof(f)
        catch
            continue                          # callable types, anonymous funcs — skip
        end
        cache_methods(f, name, env, get_return_type; min_world = world_before)
    end
end
```

- [ ] **Step 5: Run test to verify it passes**

```
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30
```

Expected: `cache_new_methods! captures overloads via world age` PASSES, including the `length(entry.methods) == 1` assertion (which would fail if `min_world` weren't being honoured).

- [ ] **Step 6: Commit**

```
git add src/symbols.jl test/runtests.jl
git commit -m "feat(SymbolServer): cache_new_methods! captures overloads via world-age diff"
```

---

### Task 4: Refactor and wire `indexpackage.jl`

The script needs two small backward-compatible changes so it can be exercised by tests against a local fixture:
1. Read `store_path` from `ARGS[5]`, defaulting to `/symcache` (matching today's behaviour for the Docker registry indexer).
2. Skip `Pkg.add` when the package is already loadable in the active project.

**Files:**
- Modify: `src/indexpackage.jl`

- [ ] **Step 1: Read `store_path` from ARGS[5]**

In `src/indexpackage.jl`, locate this line (around line 14):

```julia
store_path = "/symcache"
```

Replace with:

```julia
# /symcache is the historical Docker mount point used by the registry
# indexer; tests pass an explicit store_path as ARGS[5].
store_path = length(ARGS) >= 5 ? ARGS[5] : "/symcache"
```

- [ ] **Step 2: Skip `Pkg.add` when the package is already loadable**

In `src/indexpackage.jl`, locate the install block (around line 21-26):

```julia
try
    Pkg.add(name=string(current_package_name), version=current_package_version)
catch err
    @info "Could not install package, exiting"
    exit(20)
end
```

Replace with:

```julia
# When invoked from tests, the package is already dev-deped in the active
# project; skip the registry round-trip in that case.
already_loadable = try
    Base.identify_package(string(current_package_name)) !== nothing
catch
    false
end

if !already_loadable
    try
        Pkg.add(name=string(current_package_name), version=current_package_version)
    catch err
        @info "Could not install package, exiting"
        exit(20)
    end
end
```

- [ ] **Step 3: Capture the world stamp before package import**

In `src/indexpackage.jl`, locate this block (around line 33-42):

```julia
using .CacheStore

# Load package
m = try
    LoadingBay.eval(:(import $current_package_name))
    getfield(LoadingBay, current_package_name)
catch e
    @info "Could not load package, exiting."
    exit(10)
end
```

Replace with:

```julia
using .CacheStore

# World stamp taken before the package itself loads. method_world(m) on any
# Method added during the import will be > world_before, which is how
# cache_new_methods! discovers overloads of functions defined elsewhere.
world_before = Base.get_world_counter()

# Load package
m = try
    LoadingBay.eval(:(import $current_package_name))
    getfield(LoadingBay, current_package_name)
catch e
    @info "Could not load package, exiting."
    exit(10)
end
```

- [ ] **Step 4: Call `cache_new_methods!` after `symbols`**

In `src/indexpackage.jl`, locate this block (around line 44-46):

```julia
# Get the symbols
env = getenvtree([current_package_name])
symbols(env, m, get_return_type=true)
```

Replace with:

```julia
# Get the symbols
env = getenvtree([current_package_name])
symbols(env, m, get_return_type=true)

# Pick up overloads of functions defined elsewhere (e.g. Base.show) that
# the package added without importing the name into its own module.
cache_new_methods!(env, world_before; get_return_type=true)
```

- [ ] **Step 5: Sanity check**

```
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30
```

Expected: all pre-existing tests still pass. (The new behaviour will be exercised by Task 8.)

- [ ] **Step 6: Commit**

```
git add src/indexpackage.jl
git commit -m "feat(SymbolServer): record method overloads when indexing packages"
```

---

### Task 5: Wire into `server.jl`

**Files:**
- Modify: `src/server.jl`

- [ ] **Step 1: Capture the world stamp before the package-loading loop**

In `src/server.jl`, locate this block (around line 96-101):

```julia
# Load all packages together
# This is important, or methods added to functions in other packages that are loaded earlier would not be in the cache
for (i, uuid) in enumerate(packages_to_load)
    load_package(ctx, uuid, conn, LoadingBay, round(Int, 100*(i - 1)/length(packages_to_load)))
end
```

Replace with:

```julia
# World stamp taken before any user package is loaded. method_world(m) on
# any Method added during the loading loop will be > world_before, which
# is how cache_new_methods! (called below) discovers overloads of
# functions defined elsewhere — including overloads of Base/Core
# functions added by user packages.
world_before = Base.get_world_counter()

# Load all packages together
# This is important, or methods added to functions in other packages that are loaded earlier would not be in the cache
for (i, uuid) in enumerate(packages_to_load)
    load_package(ctx, uuid, conn, LoadingBay, round(Int, 100*(i - 1)/length(packages_to_load)))
end
```

- [ ] **Step 2: Call `cache_new_methods!` after `symbols`**

In `src/server.jl`, locate this block (around line 119-127):

```julia
symbols(env_symbols, nothing, getallns(), visited)

# Wrap the `ModuleStore`s as `Package`s.
for (pkg_name, cache) in env_symbols
    !isinmanifest(ctx, String(pkg_name)) && continue
    uuid = packageuuid(ctx, String(pkg_name))
    pe = frommanifest(ctx, uuid)
    server.depot[uuid] = Package(String(pkg_name), cache, uuid, sha_pkg(manifest_dir, pe))
end
```

Replace with:

```julia
symbols(env_symbols, nothing, getallns(), visited)

# Pick up overloads of functions defined elsewhere (e.g. Base.show) that
# user packages added without importing the name. The `min_world` filter
# inside cache_methods (driven from world_before above) ensures we only
# attribute methods that were added during the package-loading loop, so
# pre-existing methods on env entries we kept (like :Base when its cache
# wasn't already on disk) are not duplicated.
cache_new_methods!(env_symbols, world_before; get_return_type=false)

# Wrap the `ModuleStore`s as `Package`s.
for (pkg_name, cache) in env_symbols
    !isinmanifest(ctx, String(pkg_name)) && continue
    uuid = packageuuid(ctx, String(pkg_name))
    pe = frommanifest(ctx, uuid)
    server.depot[uuid] = Package(String(pkg_name), cache, uuid, sha_pkg(manifest_dir, pe))
end
```

- [ ] **Step 3: Sanity check**

```
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30
```

Expected: all pre-existing tests still pass. (The new behaviour will be exercised by Task 7.)

- [ ] **Step 4: Commit**

```
git add src/server.jl
git commit -m "feat(SymbolServer): record method overloads in getstore path"
```

---

### Task 6: Create the `testenv3` fixture

**Files:**
- Create: `test/testenv3/B/Project.toml`
- Create: `test/testenv3/B/src/B.jl`
- Create: `test/testenv3/proj/Project.toml`
- Create: `test/testenv3/proj/Manifest.toml`

- [ ] **Step 1: Create `test/testenv3/B/Project.toml`**

```toml
name = "B"
uuid = "b8d7f5ca-4a81-4f4a-b8c7-1f4a0d2b3c4e"
version = "0.1.0"
```

- [ ] **Step 2: Create `test/testenv3/B/src/B.jl`**

```julia
module B

struct BType end

# Overload Base.show without `import Base.show` — the failing case the
# method-diff change is meant to capture.
Base.show(io::IO, ::BType) = print(io, "B")
Base.show(io::IO, ::MIME"text/plain", ::BType) = print(io, "B (verbose)")

# Overload Base.length to confirm the fix generalises beyond show.
Base.length(::BType) = 0

# Own function — confirms the existing path (symbols() walking the
# package's own names) still works.
myfunc(x) = x

end # module B
```

- [ ] **Step 3: Create `test/testenv3/proj/Project.toml`**

```toml
[deps]
B = "b8d7f5ca-4a81-4f4a-b8c7-1f4a0d2b3c4e"
```

- [ ] **Step 4: Create `test/testenv3/proj/Manifest.toml`**

```toml
# This file is machine-generated - editing it directly is not advised

julia_version = "1.10.1"
manifest_format = "2.0"
project_hash = "0000000000000000000000000000000000000000"

[[deps.B]]
path = "../B"
uuid = "b8d7f5ca-4a81-4f4a-b8c7-1f4a0d2b3c4e"
version = "0.1.0"
```

(The exact `project_hash` does not matter; `Pkg.instantiate()` rewrites it on first run.)

- [ ] **Step 5: Commit**

```
git add test/testenv3
git commit -m "test(SymbolServer): add testenv3 fixture with Base.show/length overloads"
```

---

### Task 7: Integration test — `getstore` / `server.jl` path

**Files:**
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing integration test**

Append to `test/runtests.jl`:

```julia
@testitem "testenv3 captures overloads via getstore" begin
    using Pkg
    using Base: UUID

    mktempdir() do path
        cp(joinpath(@__DIR__, "testenv3"), path; force=true)

        project_path = joinpath(path, "proj")

        store_path = joinpath(path, "store")
        mkpath(store_path)

        jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do
            run(`$jl_cmd --project=$project_path --startup-file=no -e 'using Pkg; Pkg.instantiate()'`)
        end

        ssi = SymbolServerInstance("", store_path)
        ret_status, store = getstore(ssi, project_path; download=false)

        if ret_status == :failure
            @info String(take!(store))
        end
        @test ret_status == :success
        @test haskey(store, :B)

        # Inspect the on-disk cache file directly.
        cache_path = joinpath(store_path, "B",
            "B_b8d7f5ca-4a81-4f4a-b8c7-1f4a0d2b3c4e",
            "v0.1.0_nothing.jstore")
        @test isfile(cache_path)

        cached = open(SymbolServer.CacheStore.read, cache_path)
        modstore = cached.val

        # Base.show overload — the failing case the change is meant to fix.
        @test haskey(modstore, :show)
        show_entry = modstore[:show]
        @test show_entry isa SymbolServer.FunctionStore
        @test show_entry.name != show_entry.extends
        @test show_entry.extends.name == :show
        @test show_entry.extends.parent !== nothing
        @test show_entry.extends.parent.name == :Base
        @test length(show_entry.methods) >= 2

        # Base.length overload — confirms generalisation beyond show.
        @test haskey(modstore, :length)
        length_entry = modstore[:length]
        @test length_entry isa SymbolServer.FunctionStore
        @test length_entry.name != length_entry.extends
        @test length_entry.extends.name == :length
        @test length_entry.extends.parent !== nothing
        @test length_entry.extends.parent.name == :Base
        @test length(length_entry.methods) == 1

        # Own function — confirms existing path still works and is not
        # incorrectly tagged as an overload.
        @test haskey(modstore, :myfunc)
        myfunc_entry = modstore[:myfunc]
        @test myfunc_entry isa SymbolServer.FunctionStore
        @test myfunc_entry.name == myfunc_entry.extends
        @test length(myfunc_entry.methods) == 1

        SymbolServer.clear_disc_store(ssi)
        @test length(readdir(store_path)) == 0
    end
end
```

- [ ] **Step 2: Run the integration test**

```
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -80
```

Expected: `testenv3 captures overloads via getstore` PASSES along with every pre-existing test.

If `:show` / `:length` assertions fail with `haskey == false`, the wiring in `server.jl` (Task 5) is the most likely culprit — confirm both `world_before` capture and the `cache_new_methods!` call are present and in the right order.

- [ ] **Step 3: Commit**

```
git add test/runtests.jl
git commit -m "test(SymbolServer): integration test for overload capture via getstore"
```

---

### Task 8: Integration test — `indexpackage.jl` path

This test invokes `indexpackage.jl` directly as a subprocess against the same `testenv3` fixture. It exercises the registry-indexer path independently of `server.jl`/`getstore`.

**Files:**
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing integration test**

Append to `test/runtests.jl`:

```julia
@testitem "indexpackage.jl captures overloads" begin
    using Pkg

    mktempdir() do path
        cp(joinpath(@__DIR__, "testenv3"), path; force=true)

        project_path = joinpath(path, "proj")

        store_path = joinpath(path, "store")
        mkpath(store_path)

        jl_cmd = joinpath(Sys.BINDIR, Base.julia_exename())
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do
            run(`$jl_cmd --project=$project_path --startup-file=no -e 'using Pkg; Pkg.instantiate()'`)
        end

        indexpkg = abspath(joinpath(@__DIR__, "..", "src", "indexpackage.jl"))

        # ARGS[1..4] = name, version, uuid, treehash; ARGS[5] = store_path.
        # treehash is "nothing" (matches the literal string the script writes
        # into the cache filename when no tree hash is available).
        cmd = `$jl_cmd --project=$project_path --startup-file=no $indexpkg B 0.1.0 b8d7f5ca-4a81-4f4a-b8c7-1f4a0d2b3c4e nothing $store_path`
        proc = withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do
            run(ignorestatus(cmd))
        end
        # The script intentionally exits 37 on success.
        @test proc.exitcode == 37

        cache_path = joinpath(store_path, "v0.1.0_nothing.jstore")
        @test isfile(cache_path)

        cached = open(SymbolServer.CacheStore.read, cache_path)
        modstore = cached.val

        @test haskey(modstore, :show)
        show_entry = modstore[:show]
        @test show_entry isa SymbolServer.FunctionStore
        @test show_entry.name != show_entry.extends
        @test show_entry.extends.name == :show
        @test show_entry.extends.parent !== nothing
        @test show_entry.extends.parent.name == :Base
        @test length(show_entry.methods) >= 2

        @test haskey(modstore, :length)
        length_entry = modstore[:length]
        @test length_entry isa SymbolServer.FunctionStore
        @test length_entry.name != length_entry.extends
        @test length_entry.extends.name == :length
        @test length_entry.extends.parent !== nothing
        @test length_entry.extends.parent.name == :Base
        @test length(length_entry.methods) == 1

        @test haskey(modstore, :myfunc)
        myfunc_entry = modstore[:myfunc]
        @test myfunc_entry isa SymbolServer.FunctionStore
        @test myfunc_entry.name == myfunc_entry.extends
        @test length(myfunc_entry.methods) == 1
    end
end
```

- [ ] **Step 2: Run the integration test**

```
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -80
```

Expected: `indexpackage.jl captures overloads` PASSES along with every pre-existing test.

If the subprocess returns exit code 20 (`Could not install package`), the `already_loadable` check in Task 4 step 2 is not finding `B` — confirm `Base.identify_package("B")` returns non-nothing when the script runs under `--project=$project_path`.

If the subprocess returns exit code 10 (`Could not load package`), `import B` is failing — usually a precompilation or instantiation issue with the fixture; re-run the `Pkg.instantiate()` step manually under the same project to inspect.

- [ ] **Step 3: Commit**

```
git add test/runtests.jl
git commit -m "test(SymbolServer): integration test for overload capture via indexpackage.jl"
```

---

### Task 9: Final regression sweep on developer's Julia

- [ ] **Step 1: Run the full test suite once more on the local Julia**

```
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -80
```

Expected: every `@testitem` reports as passing, including:
- All pre-existing testitems (`Core and Base symbol completeness`, `VarRef loops`, `Builtins have appropriate methods`, `rand methods`, `check caching of UnionAlls`, `testenv integration`, `issues/285 testenv2`, `Sort submodule access`, `symbol documentation`, `Excluding private packages from cache download`, `TypeofVararg`, `Pipe names`, `Intrinsics`).
- `method_world reads the right field` (Task 1)
- `_samestore matches MethodStores by (file, line, sig)` (Task 2)
- `cache_new_methods! captures overloads via world age` (Task 3)
- `cache_methods min_world filter skips pre-existing methods` (Task 3)
- `testenv3 captures overloads via getstore` (Task 7)
- `indexpackage.jl captures overloads` (Task 8)

If any pre-existing test fails after these changes, the most likely cause is the dedup edit inside `cache_methods` (Task 2 step 4). Confirm `_samestore` only compares `(file, line, sig)` — comparing `name` or `mod` would over-deduplicate methods that are legitimately distinct in the cache.

- [ ] **Step 2: No additional commit needed if the suite is green.**

---

### Task 10: Multi-version regression sweep (Julia 1.10, 1.11, 1.12)

The `[compat]` entry pins `julia = "1.10"` and the codebase has version-specific branches all the way through 1.12 (see `unsorted_names` in `src/utils.jl` and the `CORE_BASE_NAMES_CONFUSION` check in `src/symbols.jl`). The new code touches a `Method` field whose name has historically varied (`primary_world` vs. `min_world`) and a kwarg-passing convention, so each supported Julia must be exercised explicitly.

This task assumes [`juliaup`](https://github.com/JuliaLang/juliaup) is installed. If it isn't, install it via the project's usual Julia install method and adapt the commands below.

- [ ] **Step 1: Make sure each supported Julia is installed via juliaup**

```
juliaup add 1.10
juliaup add 1.11
juliaup add 1.12
```

If `1.12` is not yet a stable channel on your machine, use the most recent 1.12 pre-release juliaup advertises (e.g. `1.12.0-rc1` or `1.12-nightly`). Substitute that channel name in every step below.

- [ ] **Step 2: Run the test suite on Julia 1.10**

```
julia +1.10 --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -80
```

Expected: every testitem passes. The new `_METHOD_WORLD_FIELD` const should resolve to `:primary_world` (Julia 1.10 has it).

If `cache_new_methods! captures overloads via world age` fails with a count mismatch (e.g. `length(entry.methods) == 1` is `0`), the most likely cause is that `Module(:_TestPkgWorldDiff)` on this version creates a module whose `parentmodule` is something other than `Main`; in that case the synthetic env construction in the unit test needs to mirror the real parent chain. (This was not observed during plan-writing on the developer's local Julia, but is the first thing to check on a version that fails.)

- [ ] **Step 3: Run the test suite on Julia 1.11**

```
julia +1.11 --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -80
```

Expected: every testitem passes. 1.11 introduces the `--compiled-modules=existing` path used by `getstore` (`src/SymbolServer.jl:238-242`); confirm the `testenv3 captures overloads via getstore` test still passes — it uses that branch.

- [ ] **Step 4: Run the test suite on Julia 1.12**

```
julia +1.12 --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -80
```

Expected: every testitem passes. 1.12 changes `names()` to include Core bindings in Base by default (handled by `CORE_BASE_NAMES_CONFUSION` in `src/symbols.jl:442`). If `Core and Base symbol completeness` regresses on 1.12 specifically, the change is interacting badly with that compatibility shim — re-run with `JULIA_DEBUG=SymbolServer` to see which symbols are reported missing.

If `cache_methods` fails to compile on 1.12 due to the new `min_world` kwarg, double-check that the kwarg signature uses `min_world::UInt = UInt(0)` (literal `UInt(0)`, not `0`) — Julia's kwarg defaults are evaluated at call site, and a plain `0` would be `Int` and cause a method-mismatch on the `<=` against `UInt`.

- [ ] **Step 5: One-shot wrapper (optional, for convenience)**

```
for v in 1.10 1.11 1.12; do
    echo "=== Julia $v ==="
    julia +$v --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30
done
```

This is intentionally not a substitute for the per-version steps above — it makes individual failures harder to read. Use it only after Step 2-4 are green, as a quick re-verification before pushing.

- [ ] **Step 6: No additional commit needed if all three Julias are green.**

If any version-specific test failures show up here, prefer fixing them with a `@static if VERSION ...` branch in the affected source file rather than weakening the test assertions — the codebase already uses this pattern liberally (see `src/utils.jl:66`, `src/symbols.jl:215-219`, `src/symbols.jl:442`).

---

## Notes for the implementer

- The min Julia version is 1.10 (per `Project.toml`), so `Method.primary_world` is the field on every supported version. The const fallback to `:min_world` is defensive: if a future Julia removes/renames `primary_world`, the const switches without code changes.
- `Module(:_TestPkgWorldDiff)` in the unit test creates a top-level module with `parentmodule == Main`, so `VarRef(fakemod).parent === nothing` and the synthetic env keyed by `nameof(fakemod)` is sufficient. Do not use `@__MODULE__` — `@testitem` modules have a non-trivial parent chain and would require a multi-level env to match.
- `cache_methods` allocates a `MethodStore` for *every* method of a grown function. With `min_world`, methods with `method_world(m) <= min_world` are skipped at the top of the loop, avoiding both the allocation and the post-processing — which matters for high-fanout functions like `Base.show` that have many existing methods.
- `Base.identify_package(string(name))` works under the active project: it returns the `PkgId` of `name` if the project's manifest knows about it. Tests dev-dep `B` via the project, so this returns non-nothing and the script skips `Pkg.add`. The Docker indexer path always starts with an empty project, so `identify_package` returns `nothing` and `Pkg.add` runs as before.
- The `indexpackage.jl` script writes the cache as `<store_path>/v<version>_<treehash>.jstore` — flat, not nested under `<First>/<Name>_<uuid>/...`. That nested layout is produced by `server.jl`'s `write_depot` via `get_cache_path`. Both Task 7 and Task 8 reflect their respective layouts.
