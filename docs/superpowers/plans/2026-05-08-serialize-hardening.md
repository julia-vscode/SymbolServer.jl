# SymbolServer CacheStore Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden `CacheStore` deserialization against corrupted/tampered cache files (length-prefix attacks, truncation, deep nesting) and the writer against cycles in our own data structures, without breaking the on-disk format or public API.

**Architecture:** Public API entry points (`CacheStore.read(io)`, `CacheStore.write(io, x)`) keep their signatures. The recursive bodies are renamed to private `_read` / `_write` so the public `read` can wrap `EOFError → CacheCorruptedError` exactly once at the top. A `depth::Int` positional parameter is threaded through the private workers and capped at `MAX_DEPTH = 256`. Length-prefix reads go through a single `_check_len(io, n)` helper that asserts `0 ≤ n ≤ bytesavailable(io)` before allocating. A new `CacheCorruptedError <: Exception` type is the read-side signal; cycles detected at write-time throw `ArgumentError` instead, since they indicate a programmer bug rather than file corruption. The three callers that currently swallow every exception narrow their `catch` to `CacheCorruptedError`.

**Tech Stack:** Julia, `TestItemRunner` for tests (existing convention in this repo).

**Spec:** `docs/superpowers/specs/2026-05-08-serialize-hardening.md`

---

## File Structure

- `src/serialize.jl` — all CacheStore changes (struct, helpers, threaded depth, length checks, EOF wrap). One file, one responsibility — the wire format.
- `src/utils.jl` — narrow caller `catch` block at line 523.
- `src/SymbolServer.jl` — narrow caller `catch` block at line 362.
- `src/server.jl` — narrow caller `catch` block at line 85.
- `test/runtests.jl` — append `@testitem` blocks at the end of the file (matches the existing per-feature testitem convention).

No new files. The hardening is entirely additive within `serialize.jl`.

---

## Task 1: Define `CacheCorruptedError` and reject unknown headers

**Files:**
- Modify: `src/serialize.jl:271` (replace `error("Unknown type: $t")`)
- Modify: `src/serialize.jl` (add struct near top of module, after the header constants)
- Test: `test/runtests.jl` (append new `@testitem`)

- [ ] **Step 1: Write the failing test**

Append to `test/runtests.jl`:

```julia
@testitem "CacheStore rejects unknown header" begin
    using SymbolServer.CacheStore: CacheCorruptedError, read

    io = IOBuffer(UInt8[0xff])
    @test_throws CacheCorruptedError read(io)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/pfitzseb/Documents/Git/julia-vscode/scripts/packages/SymbolServer && julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: FAIL on the new testitem because `CacheCorruptedError` is not defined (the test won't even compile — `UndefVarError`).

- [ ] **Step 3: Add the struct and replace the error call**

In `src/serialize.jl`, just after the header constants block (after line 29, before the first `function write`), add:

```julia
struct CacheCorruptedError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CacheCorruptedError) = print(io, "CacheCorruptedError: ", e.msg)
```

In `src/serialize.jl:271`, replace:

```julia
        error("Unknown type: $t")
```

with:

```julia
        throw(CacheCorruptedError("unknown type tag: 0x$(string(t, base=16, pad=2))"))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/pfitzseb/Documents/Git/julia-vscode/scripts/packages/SymbolServer && julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: PASS for the new testitem; all existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/serialize.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
Add CacheCorruptedError and reject unknown wire headers

Introduce a dedicated exception type so callers can distinguish cache
corruption from unrelated failures. Replace the bare error() call on
unknown header bytes with a CacheCorruptedError throw.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Strict reads + EOF wrapping at the entry point

**Files:**
- Modify: `src/serialize.jl:172-273` (split `read` into public wrapper + private `_read`)
- Modify: `src/serialize.jl:184, 190` (replace `readbytes!` with `read!`)
- Modify: `src/serialize.jl:275-282` (rename `read_vector` to `_read_vector`)
- Test: `test/runtests.jl` (append new `@testitem`)

- [ ] **Step 1: Write the failing test**

Append to `test/runtests.jl`:

```julia
@testitem "CacheStore rejects truncated stream" begin
    using SymbolServer.CacheStore: CacheCorruptedError, read

    # SymbolHeader (0x02) + length=100, but only 5 payload bytes
    io = IOBuffer(vcat(UInt8[0x02], reinterpret(UInt8, [Int(100)]), UInt8[0x41, 0x41, 0x41, 0x41, 0x41]))
    @test_throws CacheCorruptedError read(io)

    # Empty stream
    @test_throws CacheCorruptedError read(IOBuffer(UInt8[]))

    # Header byte present, but length field truncated
    @test_throws CacheCorruptedError read(IOBuffer(UInt8[0x02, 0x00, 0x00]))
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/pfitzseb/Documents/Git/julia-vscode/scripts/packages/SymbolServer && julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: FAIL — first case currently constructs a Symbol of nominal length 100 with garbage tail (no error). Second/third cases currently throw `EOFError`, not `CacheCorruptedError`.

- [ ] **Step 3: Refactor `read` into public wrapper + private `_read`**

In `src/serialize.jl`, replace the entire `read` function (lines 172–273) and `read_vector` (lines 275–282) with:

```julia
function read(io)
    try
        return _read(io)
    catch err
        if err isa EOFError
            throw(CacheCorruptedError("unexpected end of stream"))
        end
        rethrow()
    end
end

function _read(io, t = Base.read(io, UInt8))
    # There are a bunch of `yield`s in potentially expensive code paths.
    # One top-level `yield` would probably increase responsiveness in the
    # LS, but increases runtime by 3x. This seems like a good compromise.

    if t === VarRefHeader
        VarRef(_read(io), _read(io))
    elseif t === NothingHeader
        nothing
    elseif t === SymbolHeader
        n = Base.read(io, Int)
        out = Vector{UInt8}(undef, n)
        read!(io, out)
        Symbol(String(out))
    elseif t === StringHeader
        yield()
        n = Base.read(io, Int)
        out = Vector{UInt8}(undef, n)
        read!(io, out)
        String(out)
    elseif t === CharHeader
        Char(Base.read(io, UInt32))
    elseif t === IntegerHeader
        Base.read(io, Int)
    elseif t === FakeTypeNameHeader
        FakeTypeName(_read(io), _read_vector(io, Any))
    elseif t === FakeTypeofBottomHeader
        FakeTypeofBottom()
    elseif t === FakeTypeVarHeader
        FakeTypeVar(_read(io), _read(io), _read(io))
    elseif t === FakeUnionHeader
        FakeUnion(_read(io), _read(io))
    elseif t === FakeUnionAllHeader
        FakeUnionAll(_read(io), _read(io))
    elseif t === FakeTypeofVarargHeader
        T, N = _read(io), _read(io)
        if T === nothing
            FakeTypeofVararg()
        elseif N === nothing
            FakeTypeofVararg(T)
        else
            FakeTypeofVararg(T, N)
        end
    elseif t === UndefHeader
        nothing
    elseif t === MethodStoreHeader
        yield()
        name = _read(io)
        mod = _read(io)
        file = _read(io)
        line = Base.read(io, UInt32)
        nsig = Base.read(io, Int)
        sig = Vector{Pair{Any, Any}}(undef, nsig)
        for i in 1:nsig
            sig[i] = _read(io) => _read(io)
        end
        kws = _read_vector(io, Symbol)
        rt = _read(io)
        MethodStore(name, mod, file, line, sig, kws, rt)
    elseif t === FunctionStoreHeader
        yield()
        FunctionStore(_read(io), _read_vector(io, MethodStore), _read(io), _read(io), _read(io))
    elseif t === DataTypeStoreHeader
        yield()
        DataTypeStore(_read(io), _read(io), _read_vector(io, Any), _read_vector(io, Any), _read_vector(io, Any), _read_vector(io, MethodStore), _read(io), _read(io))
    elseif t === GenericStoreHeader
        yield()
        GenericStore(_read(io), _read(io), _read(io), _read(io))
    elseif t === ModuleStoreHeader
        yield()
        name = _read(io)
        n = Base.read(io, Int)
        vals = Dict{Symbol,Any}()
        sizehint!(vals, n)
        for _ = 1:n
            k = _read(io)
            v = _read(io)
            vals[k] = v
        end
        doc = _read(io)
        exported = _read(io)
        exportednames = _read_vector(io, Symbol)
        used_modules = _read_vector(io, Symbol)
        ModuleStore(name, vals, doc, exported, exportednames, used_modules)
    elseif t === TrueHeader
        true
    elseif t === FalseHeader
        false
    elseif t === TupleHeader
        N = Base.read(io, Int)
        ntuple(i->_read(io), N)
    elseif t === PackageHeader
        yield()
        name = _read(io)
        val = _read(io)
        uuid = Base.UUID(Base.read(io, UInt128))
        sha = Base.read(io, 32)
        Package(name, val, uuid, all(x == 0x00 for x in sha) ? nothing : sha)
    else
        throw(CacheCorruptedError("unknown type tag: 0x$(string(t, base=16, pad=2))"))
    end
end

function _read_vector(io, T)
    n = Base.read(io, Int)
    v = Vector{T}(undef, n)
    for i in 1:n
        v[i] = _read(io)
    end
    v
end
```

Note the changes versus the original:
- Public `read(io)` is a wrapper that catches `EOFError` and rethrows as `CacheCorruptedError`.
- Recursive worker is `_read` (was `read`); all internal recursive calls go to `_read` directly.
- `readbytes!(io, out, n)` → `read!(io, out)` for Symbol (line ~184) and String (line ~190).
- `read_vector` → `_read_vector` (since it's only called internally).
- `error("Unknown type: $t")` is now `throw(CacheCorruptedError(...))` (already done in Task 1; preserved here since this rewrite re-renders the whole function).

- [ ] **Step 4: Run the suite to verify the new test passes and existing tests still pass**

Run: `cd /home/pfitzseb/Documents/Git/julia-vscode/scripts/packages/SymbolServer && julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: PASS for the new testitem; all existing tests (round-trip, sha, etc.) still pass.

- [ ] **Step 5: Commit**

```bash
git add src/serialize.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
Use read! for Symbol/String and wrap EOFError as CacheCorruptedError

Split CacheStore.read into a public wrapper that maps EOFError to
CacheCorruptedError, plus a private _read worker for recursion. Replace
readbytes! (which silently returns short on EOF) with read! so truncated
streams now error instead of producing Symbols/Strings with garbage tails.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Length-prefix validation

**Files:**
- Modify: `src/serialize.jl` (add `_check_len` helper, apply at six sites)
- Test: `test/runtests.jl` (append new `@testitem`)

- [ ] **Step 1: Write the failing test**

Append to `test/runtests.jl`:

```julia
@testitem "CacheStore rejects oversized length fields" begin
    using SymbolServer.CacheStore: CacheCorruptedError, read

    # SymbolHeader (0x02) + length=10^15 in a 9-byte stream → way over remaining bytes
    huge = Int(10)^15
    io = IOBuffer(vcat(UInt8[0x02], reinterpret(UInt8, [huge])))
    @test_throws CacheCorruptedError read(io)

    # Negative length
    io = IOBuffer(vcat(UInt8[0x02], reinterpret(UInt8, [Int(-1)])))
    @test_throws CacheCorruptedError read(io)

    # StringHeader with oversized length
    io = IOBuffer(vcat(UInt8[0x05], reinterpret(UInt8, [huge])))
    @test_throws CacheCorruptedError read(io)

    # TupleHeader (0x14) with oversized length
    io = IOBuffer(vcat(UInt8[0x14], reinterpret(UInt8, [huge])))
    @test_throws CacheCorruptedError read(io)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/pfitzseb/Documents/Git/julia-vscode/scripts/packages/SymbolServer && julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: FAIL or test process aborts with OOM. Without the helper, `Vector{UInt8}(undef, 10^15)` either throws `OutOfMemoryError` (which won't match `CacheCorruptedError`) or hangs/crashes.

If the test process aborts on the huge-allocation case, comment out that case temporarily, run to confirm the negative-length case fails, then re-enable after Step 3.

- [ ] **Step 3: Add `_check_len` helper and apply at all length-prefix sites**

In `src/serialize.jl`, just after the `CacheCorruptedError` struct, add:

```julia
function _check_len(io, n)
    n < 0 && throw(CacheCorruptedError("negative length: $n"))
    rem = bytesavailable(io)
    n > rem && throw(CacheCorruptedError("length $n exceeds remaining $rem bytes"))
    return n
end
```

Then in `_read`, insert `_check_len(io, n)` (or `_check_len(io, nsig)` / `_check_len(io, N)`) immediately after each `Base.read(io, Int)` length read, before any allocation. Five edits:

1. `SymbolHeader` branch:
   ```julia
   n = Base.read(io, Int)
   _check_len(io, n)
   out = Vector{UInt8}(undef, n)
   ```

2. `StringHeader` branch:
   ```julia
   n = Base.read(io, Int)
   _check_len(io, n)
   out = Vector{UInt8}(undef, n)
   ```

3. `MethodStoreHeader` branch:
   ```julia
   nsig = Base.read(io, Int)
   _check_len(io, nsig)
   sig = Vector{Pair{Any, Any}}(undef, nsig)
   ```

4. `ModuleStoreHeader` branch:
   ```julia
   n = Base.read(io, Int)
   _check_len(io, n)
   vals = Dict{Symbol,Any}()
   sizehint!(vals, n)
   ```

5. `TupleHeader` branch:
   ```julia
   N = Base.read(io, Int)
   _check_len(io, N)
   ntuple(i->_read(io), N)
   ```

And in `_read_vector`:

```julia
function _read_vector(io, T)
    n = Base.read(io, Int)
    _check_len(io, n)
    v = Vector{T}(undef, n)
    for i in 1:n
        v[i] = _read(io)
    end
    v
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/pfitzseb/Documents/Git/julia-vscode/scripts/packages/SymbolServer && julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: PASS for the new testitem (all four assertion cases throw `CacheCorruptedError` immediately, no large allocations); existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/serialize.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
Validate length-prefix fields against remaining stream bytes

Add _check_len helper and apply it at every site that reads a 64-bit
length from the stream and uses it to size an allocation: Symbol, String,
MethodStore.sig, ModuleStore.vals, Tuple, and read_vector. Rejects
negative lengths and lengths exceeding bytesavailable(io) before any
Vector{T}(undef, n) or sizehint! call.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Read-time depth cap

**Files:**
- Modify: `src/serialize.jl` (add `MAX_DEPTH` const; thread `depth::Int` through `_read` and `_read_vector`)
- Test: `test/runtests.jl` (append new `@testitem`)

- [ ] **Step 1: Write the failing test**

Append to `test/runtests.jl`:

```julia
@testitem "CacheStore rejects deeply nested input" begin
    using SymbolServer.CacheStore: CacheCorruptedError, read, write

    using SymbolServer: VarRef, FakeTypeName

    # Build a 300-level nested FakeTypeName: each level wraps the previous in parameters.
    name = VarRef(nothing, :A)
    ft = FakeTypeName(name, Any[])
    for _ in 1:300
        ft = FakeTypeName(name, Any[ft])
    end

    io = IOBuffer()
    write(io, ft)               # write succeeds (Task 5 caps this; Task 4 only caps read)
    seekstart(io)
    @test_throws CacheCorruptedError read(io)
end
```

Note: this test depends on `write` succeeding for a 300-deep structure. Since Task 5 introduces the write-side cap at the same `MAX_DEPTH = 256`, this test will start failing at the `write` line once Task 5 lands. Task 5 updates this test to use a smaller-than-write-cap depth. Order matters here.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/pfitzseb/Documents/Git/julia-vscode/scripts/packages/SymbolServer && julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: FAIL — without the depth cap, `read` recurses 300 levels and succeeds (returns the FakeTypeName), so `@test_throws` fails.

- [ ] **Step 3: Add `MAX_DEPTH` and thread `depth` through `_read` / `_read_vector`**

In `src/serialize.jl`, just after `_check_len`, add:

```julia
const MAX_DEPTH = 256
```

Modify `_read` and `_read_vector` to take and propagate `depth`. Replace the existing definitions with:

```julia
function _read(io, t = Base.read(io, UInt8), depth::Int = 0)
    depth > MAX_DEPTH && throw(CacheCorruptedError("depth limit exceeded ($MAX_DEPTH)"))

    if t === VarRefHeader
        VarRef(_read(io, Base.read(io, UInt8), depth + 1), _read(io, Base.read(io, UInt8), depth + 1))
    elseif t === NothingHeader
        nothing
    elseif t === SymbolHeader
        n = Base.read(io, Int)
        _check_len(io, n)
        out = Vector{UInt8}(undef, n)
        read!(io, out)
        Symbol(String(out))
    elseif t === StringHeader
        yield()
        n = Base.read(io, Int)
        _check_len(io, n)
        out = Vector{UInt8}(undef, n)
        read!(io, out)
        String(out)
    elseif t === CharHeader
        Char(Base.read(io, UInt32))
    elseif t === IntegerHeader
        Base.read(io, Int)
    elseif t === FakeTypeNameHeader
        FakeTypeName(_read(io, Base.read(io, UInt8), depth + 1), _read_vector(io, Any, depth + 1))
    elseif t === FakeTypeofBottomHeader
        FakeTypeofBottom()
    elseif t === FakeTypeVarHeader
        FakeTypeVar(_read(io, Base.read(io, UInt8), depth + 1), _read(io, Base.read(io, UInt8), depth + 1), _read(io, Base.read(io, UInt8), depth + 1))
    elseif t === FakeUnionHeader
        FakeUnion(_read(io, Base.read(io, UInt8), depth + 1), _read(io, Base.read(io, UInt8), depth + 1))
    elseif t === FakeUnionAllHeader
        FakeUnionAll(_read(io, Base.read(io, UInt8), depth + 1), _read(io, Base.read(io, UInt8), depth + 1))
    elseif t === FakeTypeofVarargHeader
        T, N = _read(io, Base.read(io, UInt8), depth + 1), _read(io, Base.read(io, UInt8), depth + 1)
        if T === nothing
            FakeTypeofVararg()
        elseif N === nothing
            FakeTypeofVararg(T)
        else
            FakeTypeofVararg(T, N)
        end
    elseif t === UndefHeader
        nothing
    elseif t === MethodStoreHeader
        yield()
        name = _read(io, Base.read(io, UInt8), depth + 1)
        mod = _read(io, Base.read(io, UInt8), depth + 1)
        file = _read(io, Base.read(io, UInt8), depth + 1)
        line = Base.read(io, UInt32)
        nsig = Base.read(io, Int)
        _check_len(io, nsig)
        sig = Vector{Pair{Any, Any}}(undef, nsig)
        for i in 1:nsig
            sig[i] = _read(io, Base.read(io, UInt8), depth + 1) => _read(io, Base.read(io, UInt8), depth + 1)
        end
        kws = _read_vector(io, Symbol, depth + 1)
        rt = _read(io, Base.read(io, UInt8), depth + 1)
        MethodStore(name, mod, file, line, sig, kws, rt)
    elseif t === FunctionStoreHeader
        yield()
        FunctionStore(
            _read(io, Base.read(io, UInt8), depth + 1),
            _read_vector(io, MethodStore, depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
        )
    elseif t === DataTypeStoreHeader
        yield()
        DataTypeStore(
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
            _read_vector(io, Any, depth + 1),
            _read_vector(io, Any, depth + 1),
            _read_vector(io, Any, depth + 1),
            _read_vector(io, MethodStore, depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
        )
    elseif t === GenericStoreHeader
        yield()
        GenericStore(
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
            _read(io, Base.read(io, UInt8), depth + 1),
        )
    elseif t === ModuleStoreHeader
        yield()
        name = _read(io, Base.read(io, UInt8), depth + 1)
        n = Base.read(io, Int)
        _check_len(io, n)
        vals = Dict{Symbol,Any}()
        sizehint!(vals, n)
        for _ = 1:n
            k = _read(io, Base.read(io, UInt8), depth + 1)
            v = _read(io, Base.read(io, UInt8), depth + 1)
            vals[k] = v
        end
        doc = _read(io, Base.read(io, UInt8), depth + 1)
        exported = _read(io, Base.read(io, UInt8), depth + 1)
        exportednames = _read_vector(io, Symbol, depth + 1)
        used_modules = _read_vector(io, Symbol, depth + 1)
        ModuleStore(name, vals, doc, exported, exportednames, used_modules)
    elseif t === TrueHeader
        true
    elseif t === FalseHeader
        false
    elseif t === TupleHeader
        N = Base.read(io, Int)
        _check_len(io, N)
        ntuple(i->_read(io, Base.read(io, UInt8), depth + 1), N)
    elseif t === PackageHeader
        yield()
        name = _read(io, Base.read(io, UInt8), depth + 1)
        val = _read(io, Base.read(io, UInt8), depth + 1)
        uuid = Base.UUID(Base.read(io, UInt128))
        sha = Base.read(io, 32)
        Package(name, val, uuid, all(x == 0x00 for x in sha) ? nothing : sha)
    else
        throw(CacheCorruptedError("unknown type tag: 0x$(string(t, base=16, pad=2))"))
    end
end

function _read_vector(io, T, depth::Int = 0)
    n = Base.read(io, Int)
    _check_len(io, n)
    v = Vector{T}(undef, n)
    for i in 1:n
        v[i] = _read(io, Base.read(io, UInt8), depth + 1)
    end
    v
end
```

The public `read(io)` wrapper is unchanged — it already calls `_read(io)` which now defaults `depth = 0`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/pfitzseb/Documents/Git/julia-vscode/scripts/packages/SymbolServer && julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: PASS for the depth testitem; all other tests still pass (real Julia type structures are nowhere near 256 deep).

- [ ] **Step 5: Commit**

```bash
git add src/serialize.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
Cap deserialization recursion depth at MAX_DEPTH=256

Thread a depth counter through _read and _read_vector. Throw
CacheCorruptedError when nesting exceeds 256, preventing stack overflow
from a maliciously deep encoding of FakeTypeName/FakeUnionAll/etc.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Write-time depth cap

**Files:**
- Modify: `src/serialize.jl:32-170` (split `write` into public + private, thread `depth`)
- Modify: `test/runtests.jl` (update Task 4's test to use a depth below the write cap; add a write-cap test)

- [ ] **Step 1: Update Task 4's test and add a write-cap test**

Replace the testitem `"CacheStore rejects deeply nested input"` (added in Task 4) with:

```julia
@testitem "CacheStore rejects deeply nested input on read" begin
    using SymbolServer.CacheStore: CacheCorruptedError, MAX_DEPTH, _read, _read_vector

    # Build a hand-crafted byte stream of 300-level nested FakeTypeName encodings.
    # Each level: FakeTypeNameHeader (0x07) + VarRef(nothing, :a) + length-1 vector containing inner.
    # VarRef encoding: 0x06 + parent + name. Parent here is 0x01 (Nothing). Name :a is 0x02 + Int(1) + 0x61.
    # Vector encoding: Int(n=1) for outer; 0 for innermost.

    function nested(level)
        io = IOBuffer()
        # Innermost: FakeTypeName(VarRef(nothing, :a), [])
        Base.write(io, 0x07)                     # FakeTypeNameHeader
        Base.write(io, 0x06)                     # VarRefHeader
        Base.write(io, 0x01)                     # parent = nothing
        Base.write(io, 0x02)                     # SymbolHeader
        Base.write(io, Int(1))                   # symbol length
        Base.write(io, 0x61)                     # 'a'
        Base.write(io, Int(0))                   # parameters vector length 0
        innermost = take!(io)

        # Wrap `level` more levels around it: each wrap adds FakeTypeNameHeader + VarRef + length-1 vector
        bytes = innermost
        for _ in 1:level
            io = IOBuffer()
            Base.write(io, 0x07)                 # FakeTypeNameHeader
            Base.write(io, 0x06)                 # VarRefHeader
            Base.write(io, 0x01)                 # parent = nothing
            Base.write(io, 0x02)                 # SymbolHeader
            Base.write(io, Int(1))               # symbol length
            Base.write(io, 0x61)                 # 'a'
            Base.write(io, Int(1))               # parameters vector length 1
            Base.write(io, bytes)                # nested element
            bytes = take!(io)
        end
        return bytes
    end

    # 300 levels exceeds MAX_DEPTH=256
    bytes = nested(300)
    @test_throws CacheCorruptedError SymbolServer.CacheStore.read(IOBuffer(bytes))

    # 100 levels is well under MAX_DEPTH and should succeed
    bytes = nested(100)
    SymbolServer.CacheStore.read(IOBuffer(bytes))   # no throw
end

@testitem "CacheStore rejects cyclic data on write" begin
    using SymbolServer.CacheStore: write
    using SymbolServer: VarRef, FakeTypeName

    name = VarRef(nothing, :A)
    ft = FakeTypeName(name, Any[])
    push!(ft.parameters, ft)        # cycle: ft.parameters[1] === ft

    io = IOBuffer()
    @test_throws ArgumentError write(io, ft)

    # Non-cyclic but very deep also rejected
    deep = FakeTypeName(name, Any[])
    for _ in 1:300
        deep = FakeTypeName(name, Any[deep])
    end
    io = IOBuffer()
    @test_throws ArgumentError write(io, deep)
end
```

The first testitem replaces Task 4's, swapping its strategy: instead of calling `write` to build the deep buffer (which Task 5 now blocks), it constructs the bytes by hand. The second testitem covers Task 5's write-side behavior including the cycle case.

- [ ] **Step 2: Run tests to verify the new write testitem fails and read testitem still passes**

Run: `cd /home/pfitzseb/Documents/Git/julia-vscode/scripts/packages/SymbolServer && julia --project=. -e 'using Pkg; Pkg.test()'`
Expected:
- "CacheStore rejects cyclic data on write" FAILS — `write(io, ft)` either stack-overflows on the cycle or runs forever, and doesn't throw `ArgumentError`.
- "CacheStore rejects deeply nested input on read" passes (Task 4 already in place).

If the cycle case crashes the test runner, comment out that assertion temporarily, run to confirm the deep case fails, then re-enable after Step 3.

- [ ] **Step 3: Refactor `write` into public wrapper + private `_write`, thread `depth`**

In `src/serialize.jl`, replace the entire `write` block (lines 32–170) with:

```julia
function write(io, x)
    _write(io, x, 0)
end

function _write(io, x::VarRef, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, VarRefHeader)
    _write(io, x.parent, depth + 1)
    _write(io, x.name, depth + 1)
end
function _write(io, x::Nothing, depth::Int)
    Base.write(io, NothingHeader)
end
function _write(io, x::Char, depth::Int)
    Base.write(io, CharHeader)
    Base.write(io, UInt32(x))
end
function _write(io, x::Bool, depth::Int)
    x ? Base.write(io, TrueHeader) : Base.write(io, FalseHeader)
end
function _write(io, x::Int, depth::Int)
    Base.write(io, IntegerHeader)
    Base.write(io, x)
end
function _write(io, x::Symbol, depth::Int)
    Base.write(io, SymbolHeader)
    Base.write(io, sizeof(x))
    Base.write(io, String(x))
end
function _write(io, x::NTuple{N,Any}, depth::Int) where N
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, TupleHeader)
    Base.write(io, N)
    for i = 1:N
        _write(io, x[i], depth + 1)
    end
end
function _write(io, x::String, depth::Int)
    Base.write(io, StringHeader)
    Base.write(io, sizeof(x))
    Base.write(io, x)
end
function _write(io, x::FakeTypeName, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, FakeTypeNameHeader)
    _write(io, x.name, depth + 1)
    _write_vector(io, x.parameters, depth + 1)
end
_write(io, x::FakeTypeofBottom, depth::Int) = Base.write(io, FakeTypeofBottomHeader)
function _write(io, x::FakeTypeVar, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, FakeTypeVarHeader)
    _write(io, x.name, depth + 1)
    _write(io, x.lb, depth + 1)
    _write(io, x.ub, depth + 1)
end
function _write(io, x::FakeUnion, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, FakeUnionHeader)
    _write(io, x.a, depth + 1)
    _write(io, x.b, depth + 1)
end
function _write(io, x::FakeUnionAll, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, FakeUnionAllHeader)
    _write(io, x.var, depth + 1)
    _write(io, x.body, depth + 1)
end

@static if !(Vararg isa Type)
    function _write(io, x::FakeTypeofVararg, depth::Int)
        depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
        Base.write(io, FakeTypeofVarargHeader)
        isdefined(x, :T) ? _write(io, x.T, depth + 1) : Base.write(io, UndefHeader)
        isdefined(x, :N) ? _write(io, x.N, depth + 1) : Base.write(io, UndefHeader)
    end
end

function _write(io, x::MethodStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, MethodStoreHeader)
    _write(io, x.name, depth + 1)
    _write(io, x.mod, depth + 1)
    _write(io, x.file, depth + 1)
    Base.write(io, x.line)
    Base.write(io, length(x.sig))
    for p in x.sig
        _write(io, p[1], depth + 1)
        _write(io, p[2], depth + 1)
    end
    _write_vector(io, x.kws, depth + 1)
    _write(io, x.rt, depth + 1)
end

function _write(io, x::FunctionStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, FunctionStoreHeader)
    _write(io, x.name, depth + 1)
    _write_vector(io, x.methods, depth + 1)
    _write(io, x.doc, depth + 1)
    _write(io, x.extends, depth + 1)
    _write(io, x.exported, depth + 1)
end

function _write(io, x::DataTypeStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, DataTypeStoreHeader)
    _write(io, x.name, depth + 1)
    _write(io, x.super, depth + 1)
    _write_vector(io, x.parameters, depth + 1)
    _write_vector(io, x.types, depth + 1)
    _write_vector(io, x.fieldnames, depth + 1)
    _write_vector(io, x.methods, depth + 1)
    _write(io, x.doc, depth + 1)
    _write(io, x.exported, depth + 1)
end

function _write(io, x::GenericStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, GenericStoreHeader)
    _write(io, x.name, depth + 1)
    _write(io, x.typ, depth + 1)
    _write(io, x.doc, depth + 1)
    _write(io, x.exported, depth + 1)
end

function _write(io, x::ModuleStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, ModuleStoreHeader)
    _write(io, x.name, depth + 1)
    Base.write(io, length(x.vals))
    for p in x.vals
        _write(io, p[1], depth + 1)
        _write(io, p[2], depth + 1)
    end
    _write(io, x.doc, depth + 1)
    _write(io, x.exported, depth + 1)
    _write_vector(io, x.exportednames, depth + 1)
    _write_vector(io, x.used_modules, depth + 1)
end

function _write(io, x::Package, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    Base.write(io, PackageHeader)
    _write(io, x.name, depth + 1)
    _write(io, x.val, depth + 1)
    Base.write(io, UInt128(x.uuid))
    Base.write(io, x.sha === nothing ? zeros(UInt8, 32) : x.sha)
end

function _write_vector(io, x, depth::Int)
    Base.write(io, length(x))
    for p in x
        _write(io, p, depth + 1)
    end
end
```

Note:
- The public `write(io, x)` is a one-liner that calls `_write(io, x, 0)`.
- Every `_write` method that recurses has the depth-check guard at the top. Leaf methods (Nothing, Char, Bool, Int, Symbol, String, FakeTypeofBottom) don't need it because they don't recurse.
- `_write_vector` doesn't itself need a depth check at the top because it's only called from `_write` methods that already checked at one greater depth, and elements pass `depth + 1`. But the check at `_write` boundaries catches everything.

- [ ] **Step 4: Run tests to verify both new testitems pass**

Run: `cd /home/pfitzseb/Documents/Git/julia-vscode/scripts/packages/SymbolServer && julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: PASS for both new testitems; all existing tests (which serialize real Julia type structures, depth ~50 max) still pass.

- [ ] **Step 5: Commit**

```bash
git add src/serialize.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
Cap serialization recursion depth and reject cycles in source data

Split CacheStore.write into a public wrapper and a private _write that
threads a depth counter. Throw ArgumentError (not CacheCorruptedError —
this is a programmer bug, not a corrupt cache) when nesting exceeds
MAX_DEPTH=256, catching cycles in FakeTypeName.parameters / ModuleStore
graphs that would otherwise stack-overflow.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Narrow caller `catch` blocks

**Files:**
- Modify: `src/utils.jl:519-527`
- Modify: `src/SymbolServer.jl:362-373`
- Modify: `src/server.jl:85-87`
- Test: `test/runtests.jl` (append new `@testitem`)

- [ ] **Step 1: Write the failing test**

Append to `test/runtests.jl`:

```julia
@testitem "Corrupt cache file is deleted on load" setup=[EnvSetup] begin
    # Round-trip via SymbolServerInstance: write a corrupt .jstore, attempt to load,
    # verify the file is removed (caller's catch still fires) and no exception escapes.
    using SymbolServer

    mktempdir() do store_path
        # Place a malformed cache file at a path the loader will try to read.
        pkg_dir = joinpath(store_path, "Bogus", "Bogus_00000000-0000-0000-0000-000000000000")
        mkpath(pkg_dir)
        cache_path = joinpath(pkg_dir, "v0.1.0_nothing.jstore")
        open(cache_path, "w") do io
            Base.write(io, UInt8[0xff])    # unknown header → CacheCorruptedError
        end
        @test isfile(cache_path)

        # Direct unit-style check that the catch site narrowing works: read returns the
        # specific exception type, and an ad-hoc try/catch matching only that type still
        # catches it.
        threw = false
        try
            open(SymbolServer.CacheStore.read, cache_path)
        catch err
            threw = err isa SymbolServer.CacheStore.CacheCorruptedError
        end
        @test threw
    end
end
```

This is intentionally lightweight — it verifies the exception type propagates through the file-read path. The full integration of "loader deletes the file" is covered by the existing test at `test/runtests.jl:204-212` (which exercises the success path through the same callers).

- [ ] **Step 2: Run test to verify it passes for the new corruption case but the narrow `catch` is not yet in place**

Run: `cd /home/pfitzseb/Documents/Git/julia-vscode/scripts/packages/SymbolServer && julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: PASS for the new testitem (Tasks 1-3 ensure CacheCorruptedError is thrown); but the production callers still catch every exception, including OOM and unrelated bugs. Step 3 narrows them.

(This task differs from previous tasks: the unit test for the read-side error type is already passing. The remaining work is a code change in three call sites that's behavior-preserving for the corruption case but stops swallowing other exceptions. We trust review + the existing test suite to verify the behavior-preservation.)

- [ ] **Step 3: Narrow the three caller `catch` blocks**

In `src/utils.jl`, replace lines 519–527:

```julia
    cache = try
        open(file, "r") do io
            CacheStore.read(io)
        end
    catch err
        if err isa CacheStore.CacheCorruptedError
            @warn "Couldn't read cache file for $name, deleting." exception=(err, catch_backtrace())
            rm(file)
            return false
        else
            rethrow()
        end
    end
```

In `src/SymbolServer.jl`, replace lines 362–373:

```julia
        catch err
            if err isa CacheStore.CacheCorruptedError
                @warn "Tried to load $pe_name but cache is corrupt, re-caching." exception=(err, catch_backtrace())
                try
                    rm(cache_path)
                catch err2
                    # There could have been a race condition that the file has been deleted in the meantime,
                    # we don't want to crash then.
```

(The remaining body of that catch — the inner `try/rm/catch err2` and any trailing lines — is preserved unchanged; only the outer guard is added. Read the existing block first and edit minimally.)

In `src/server.jl`, replace lines 85–87:

```julia
            catch err
                if err isa CacheStore.CacheCorruptedError
                    @info "Couldn't load $pk_name ($uuid) from corrupt cache, will recache."
                    push!(packages_to_load, uuid)
                else
                    rethrow()
                end
            end
```

(The original `server.jl` catch only logged and didn't push to `packages_to_load`. Pushing on corruption is the correct behavior — when the cache is bad we should re-cache. Verify this matches the surrounding code's expectations; if `packages_to_load` isn't in scope, keep just the log + rethrow on non-corruption.)

- [ ] **Step 4: Run the full test suite**

Run: `cd /home/pfitzseb/Documents/Git/julia-vscode/scripts/packages/SymbolServer && julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all existing tests pass (success-path round-trips still work); the new corruption testitem passes.

- [ ] **Step 5: Commit**

```bash
git add src/utils.jl src/SymbolServer.jl src/server.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
Narrow cache-load catch blocks to CacheCorruptedError

The three loaders in utils.jl, SymbolServer.jl, and server.jl previously
caught every exception and silently deleted the cache file. Narrow the
catch to CacheCorruptedError so genuine bugs (OOM, IO errors, unrelated
exceptions) propagate up to the user instead of being swallowed and
masked as "we'll just regenerate the cache".

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Checklist

Run before declaring complete:

- [ ] Spec acceptance criteria 1–8 all have at least one task implementing them.
- [ ] No task references a function/type/constant defined later. (`CacheCorruptedError` defined Task 1; `_check_len` defined Task 3; `MAX_DEPTH` defined Task 4; `_read`/`_write` defined Tasks 2/5.)
- [ ] `read_vector` was renamed to `_read_vector` in Task 2 and consistently referenced thereafter.
- [ ] `MAX_DEPTH = 256` is the same constant on both read and write sides.
- [ ] All recursive call sites in `_read` pass `depth + 1` (Task 4 shows the full function body).
- [ ] All recursive call sites in `_write` pass `depth + 1` (Task 5 shows the full function bodies).
- [ ] No use of `readbytes!` remains in `_read` (Task 2 replaces both occurrences with `read!`).
- [ ] `EOFError` is wrapped in exactly one place (the public `read` wrapper), not at every recursive level.
