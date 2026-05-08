# SymbolServer CacheStore Hardening — Spec

**Date:** 2026-05-08
**Scope:** `src/serialize.jl` (the `CacheStore` module) and its three callers.

## Problem

`CacheStore.read` deserializes binary cache files (`*.jstore`) without bounds-checking length-prefixed fields, without depth limits, and without distinguishing cache-corruption errors from unrelated failures. A corrupted local file or a tampered cloud-cache download can:

1. Cause unbounded memory allocation (`Vector{T}(undef, n)` / `Dict` `sizehint!` with attacker-controlled `n`).
2. Cause silent partial reads — `readbytes!` returns short instead of erroring, producing `Symbol`/`String` values whose nominal length exceeds their initialized content.
3. Spend unbounded time iterating loops driven by stream-controlled counts.
4. Stack-overflow Julia via deeply nested `FakeTypeName` / `FakeUnion` / `FakeUnionAll` encodings.

The writer side has its own correctness gap: cyclic data structures (`FakeTypeName.parameters` containing a back-reference, etc.) cause infinite recursion at serialization time with no useful diagnostic.

Existing callers (`utils.jl:519`, `SymbolServer.jl:338`, `server.jl:75`) wrap reads in broad `try ... catch err`, swallowing every exception and deleting/recaching the file — including unrelated errors like `OutOfMemoryError` or genuine bugs.

## Goals

- Reject malformed cache files deterministically and quickly, with a typed exception.
- Catch cycles in our own data structures at write-time before they segfault.
- Let callers distinguish "cache is corrupt, regenerate it" from "something else went wrong, surface it".
- Preserve the existing on-disk wire format; no version bump, no migration.
- Preserve the existing public API (`CacheStore.read(io)`, `CacheStore.write(io, x)`).

## Non-goals

- No iterative rewrite of the recursive deserializer. The recursion mirrors the data structure; an explicit stack machine would significantly hurt readability for marginal benefit.
- No checksum/signing of cache files. (Worth doing eventually, separate scope.)
- No format versioning. (Same.)
- No defense against pathological-but-valid inputs that fit within the size budget. The bounds keep resource use proportional to the input size, no further.

## Threat Model

Two distinct concerns, both in scope:

1. **Cache-file corruption / tampering.** Files on disk may be truncated by crashes, corrupted by bit rot, or replaced by a malicious cloud cache. The reader must reject these without exhausting resources.
2. **Cycles in our own data structures.** The writer must fail fast with a useful error if a `ModuleStore`/`FakeTypeName`/etc. graph contains a cycle, instead of recursing until the stack overflows.

Out of scope: a determined attacker who controls cache-file content but stays within the size budget can still produce slow-to-process but bounded inputs. We accept this.

## Design

### 1. `CacheCorruptedError` exception type

New type defined inside the `CacheStore` module:

```julia
struct CacheCorruptedError <: Exception
    msg::String
end
```

Not exported from `SymbolServer`. Callers reference it as `CacheStore.CacheCorruptedError`. Thrown from the read side only.

### 2. Length validation

A single helper:

```julia
function _check_len(io, n)
    n < 0 && throw(CacheCorruptedError("negative length: $n"))
    rem = bytesavailable(io)
    n > rem && throw(CacheCorruptedError("length $n exceeds remaining $rem bytes"))
end
```

Applied at every site where a 64-bit length is read from the stream and used to allocate or iterate:

- Symbol payload (currently `serialize.jl:182`)
- String payload (`:188`)
- `MethodStore.sig` count (`:223`)
- `ModuleStore.vals` count (`:243`)
- Tuple element count (`:261`)
- `read_vector` count (`:276`)

`bytesavailable` is correct for both `IOBuffer` and `IOStream` (the only callers today).

### 3. Strict reads for Symbol/String

Replace `readbytes!(io, out, n)` with `read!(io, out)` at the Symbol and String branches. `read!` throws `EOFError` on short read; `readbytes!` silently returns short. The wrapping below converts `EOFError` to `CacheCorruptedError`.

### 4. EOF wrapping at the entry point

The public `read(io)` entry point wraps its body in a `try ... catch ::EOFError` that rethrows as `CacheCorruptedError("unexpected end of stream")`. Internal recursive calls don't need their own wrapping — the entry-point wrap catches all of them.

### 5. Depth cap (read + write)

```julia
const MAX_DEPTH = 256
```

A `depth::Int` positional parameter is threaded through:

- `read(io, t = ..., depth::Int = 0)` — recursive calls pass `depth + 1`.
- `read_vector(io, T, depth::Int = 0)` — element reads pass `depth + 1`.
- `write(io, x, depth::Int = 0)` — recursive calls pass `depth + 1`.
- `write_vector(io, x, depth::Int = 0)` — element writes pass `depth + 1`.

When `depth > MAX_DEPTH`:
- **Read side:** throw `CacheCorruptedError("depth limit exceeded ($MAX_DEPTH)")`.
- **Write side:** throw `ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))")`.

The two error types are intentionally different. A read-side depth violation means the input is bad. A write-side depth violation means *our* data is bad — almost always a cycle, never a legitimate cache file.

`MAX_DEPTH = 256` is well above any realistic Julia type/module nesting (~50 even for dense generics), and bounds the call-stack frames added by serialization to a few KB — far under the default Julia stack.

### 6. Caller catch narrowing

Three call sites currently catch all exceptions and delete the cache file. Narrow them so only `CacheCorruptedError` triggers delete-and-recache; other exceptions propagate.

- `src/utils.jl:523` — `catch err` block; rm + warn only on `CacheCorruptedError`.
- `src/SymbolServer.jl:362` — same.
- `src/server.jl:85` — same.

## Out-of-scope for this change

- The depth cap on the **write** side does not currently detect cycles encoded across `ModuleStore.vals` Dict entries — only the recursive call chain is tracked. A true cycle detector would need an `IdDict` of visited objects. The depth cap is sufficient because real cycles produce deep recursion that hits the cap; we accept that the error message says "depth exceeded" rather than "cycle detected".
- `bytesavailable` is conservative for non-buffered streams (sockets, pipes). All current callers use file streams where it's exact. Future streaming users will get spurious failures and discover this.
- The `MethodStore.line` field is `Int32` in the struct definition but the reader uses `Base.read(io, UInt32)` (signed/unsigned mismatch, same byte width). Not a length-bounds issue, not in scope here.

## Acceptance Criteria

1. A 1-byte file with an unrecognized header throws `CacheCorruptedError`, not `ErrorException`.
2. A truncated file (cut mid-Symbol-payload) throws `CacheCorruptedError`, not silently producing a Symbol with garbage.
3. A file whose length field exceeds remaining bytes throws `CacheCorruptedError` immediately, with no large allocation attempted.
4. A 300-level nested `FakeTypeName` encoding throws `CacheCorruptedError` from the reader.
5. A self-referential `FakeTypeName` (cycle) throws `ArgumentError` from the writer instead of stack-overflowing.
6. All three callers (`utils.jl`, `SymbolServer.jl`, `server.jl`) delete and recache the file on `CacheCorruptedError` but propagate other exceptions unchanged.
7. Existing test suite passes: full round-trip serialization of `Base` and `Core` symbols still works, `cached_version.sha` test still works.
8. No public-API breakage: `CacheStore.read(io)` and `CacheStore.write(io, x)` keep their signatures.

## Open Questions

None — all resolved during design discussion.
