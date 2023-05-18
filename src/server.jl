
import Sockets
import SymbolServer

!in("@stdlib", LOAD_PATH) && push!(LOAD_PATH, "@stdlib") # Make sure we can load stdlibs

pipename = length(ARGS) > 1 ? ARGS[2] : nothing
conn = pipename !== nothing ? Sockets.connect(pipename) : nothing

# Try to lower the priority of this process so that it doesn't block the
# user system.
@static if Sys.iswindows()
    # Get process handle
    p_handle = ccall(:GetCurrentProcess, stdcall, Ptr{Cvoid}, ())

    # Set BELOW_NORMAL_PRIORITY_CLASS
    ret = ccall(:SetPriorityClass, stdcall, Cint, (Ptr{Cvoid}, Culong), p_handle, 0x00004000)
    ret != 1 && @warn "Something went wrong when setting BELOW_NORMAL_PRIORITY_CLASS."
else
    ret = ccall(:nice, Cint, (Cint,), 1)
    # We don't check the return value because it doesn't really matter
end

store_path = length(ARGS) > 0 ? ARGS[1] : abspath(joinpath(@__DIR__, "..", "store"))

SymbolServer.index_packages(conn, store_path)

println(conn, "DONE")
close(conn)
