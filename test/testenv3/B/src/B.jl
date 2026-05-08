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
