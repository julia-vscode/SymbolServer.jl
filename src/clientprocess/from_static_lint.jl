using LibGit2

mutable struct Server
   storedir::String
   context::Pkg.Types.Context
   depot::Dict
end

struct PackageID
    name::String
    uuid::String
end

abstract type SymStore end

mutable struct ModuleStore <: SymStore
    name::String
    vals::Dict{String,Any}
    exported::Set{String}
    doc::String
    ver::String
    sha
end
ModuleStore(name::String) = ModuleStore(name, Dict{String,Any}(), Set{String}(), "", "", nothing)

struct MethodStore <: SymStore
    file::String
    line::Int
    args::Vector{Tuple{String,String}}
end

struct FunctionStore <: SymStore
    methods::Vector{MethodStore}
    doc::String
end

struct abstractStore <: SymStore
    params::Vector{String}
    doc::String
end

struct primitiveStore <: SymStore
    params::Vector{String}
    doc::String
end

struct structStore <: SymStore
    params::Vector{String}
    fields::Vector{String}
    ts::Vector{String}
    methods::Vector{MethodStore}
    doc::String
end

struct genericStore <: SymStore
    t::String
    params::Vector{String}
    doc::String
end


function _getdoc(x)
    # Packages can add methods to Docs.doc, and those can have a bug,
    # and we don't want that to kill the symbol server process
    try
        return string(Docs.doc(x))
    catch err
        @warn "Couldn't retrieve docs."
        return ""
    end
end

function read_methods(x)
    map(methods(x)) do m
        path = isabspath(String(m.file)) ? String(m.file) : Base.find_source_file(String(m.file))
        if path == nothing
            path = ""
        end
        MethodStore(path,
                    m.line,
                    Base.arg_decl_parts(m)[2][2:end])
    end
end

function collect_params(t, params = [])
    if t isa UnionAll
        push!(params, t.var)
        return collect_params(t.body, params)
    else
        return t, params
    end
end

function import_package_names(pkg::PackageID, depot, c, m = nothing)
    if pkg.uuid in keys(depot)
        return depot[pkg.uuid]
    else
        depot[pkg.uuid] = ModuleStore(pkg.name)
        depot[pkg.uuid].ver = pkg_ver(pkg, c)
    end
    path = pkg_path(pkg, c)
    if path isa String && isdir(path) && isgitrepo(path)
        depot[pkg.uuid].sha = getgithash(path)
    end
    if m isa Module
    elseif Symbol(pkg.name) in names(Main, all = true)
        m = getfield(Main, Symbol(pkg.name))
    else
        m = try
            Main.eval(:(import $(Symbol(pkg.name))))
            m = getfield(Main, Symbol(pkg.name))
        catch
            nothing
        end
    end
    if m isa Module
        get_module_names(m, pkg, depot, depot[pkg.uuid], c)
    end
    for dep in pkg_deps(pkg, c)
        depid = PackageID(first(dep), string(last(dep)))
        if !haskey(depot, depid.uuid)
            import_package_names(depid, depot, c)
        end
    end
    return depot[pkg.uuid]
end

function get_module_names(m::Module, pkg::PackageID, depot, out::ModuleStore, c::Pkg.Types.Context)
    out.doc = string(Docs.doc(m))
    out.exported = Set{String}(string.(names(m)))
    allnames = names(m, all = true, imported = true)
    for n in allnames
        !isdefined(m, n) && continue
        startswith(string(n), "#") && continue
        if Base.isdeprecated(m, n)
        else
            x = getfield(m, n)
            t, p = collect_params(x)
            if x isa Function
                out.vals[String(n)] = FunctionStore(read_methods(x), _getdoc(x))
            elseif t isa DataType
                if t.abstract
                    out.vals[String(n)] = abstractStore(string.(p), _getdoc(x))
                elseif t.isbitstype
                        out.vals[String(n)] = primitiveStore(string.(p), _getdoc(x))
                elseif !(isempty(t.types) || Base.isvatuple(t)) || t.mutable
                        out.vals[String(n)] = structStore(string.(p),
                                                     collect(string.(fieldnames(t))),
                                                     string.(collect(t.types)),
                                                     read_methods(x),
                                                     _getdoc(x))
                else
                    out.vals[String(n)] = genericStore("DataType", string.(p), _getdoc(x))
                end
            elseif x isa Module && x != m # include reference to current module
                if parentmodule(x) == m # load non-imported submodules
                    out.vals[String(n)] = ModuleStore(String(n))
                    get_module_names(x, pkg, depot, out.vals[String(n)], c)
                end
            else
                out.vals[String(n)] = genericStore(string(typeof(x)), [], _getdoc(x))
            end
        end
    end
    for dep in pkg_deps(pkg, c)
        depid = PackageID(first(dep), string(last(dep)))
        dep_module = can_access(m, Symbol(depid.name))
        if dep_module isa Module
            out.vals[depid.name] = depid.name
            if !haskey(depot, depid.uuid)
                import_package_names(depid, depot, c, dep_module)
            end
        end
    end
end


function load_core()
    c = Pkg.Types.Context()
    depot = Dict{String,Any}()
    for m in (Base,Core)
        depot[string(m)] = ModuleStore(string(m))
        get_module_names(m, PackageID(string(m), ""), depot, depot[string(m)], c)
    end

    # Add special cases
    push!(depot["Base"].exported, "include")
    depot["Base"].vals["@."] = depot["Base"].vals["@__dot__"]
    push!(depot["Base"].exported, "@.")
    delete!(depot["Core"].exported, "Main")
    return depot
end


function save_store_to_disc(store, file)
    io = open(file, "w")
    serialize(io, store)
    close(io)
end

function pkg_deps(pkg::PackageID, c::Pkg.Types.Context)
    if VERSION < v"1.1.0-DEV.857"
        if haskey(c.env.manifest, pkg.name)
            return get(c.env.manifest[pkg.name][1], "deps", Dict{Any,Any}())
        else
            return Dict{Any,Any}()
        end
    else
        if !isempty(pkg.uuid) && haskey(c.env.manifest, Base.UUID(pkg.uuid))
            return c.env.manifest[Base.UUID(pkg.uuid)].deps
        else
            return Dict{String,Base.UUID}()
        end
    end
end

function context_deps(c::Pkg.Types.Context)
    if VERSION < v"1.1.0-DEV.857"
        c.env.project["deps"]
    else
        c.env.project.deps
    end
end


function pkg_ver(pkg::PackageID, c::Pkg.Types.Context)
    if VERSION < v"1.1.0-DEV.857"
        if haskey(c.env.manifest, pkg.name)
            return get(c.env.manifest[pkg.name][1], "version", "")
        else
            return ""
        end
    else
        if !isempty(pkg.uuid) && haskey(c.env.manifest, Base.UUID(pkg.uuid))
            return get(c.env.manifest[Base.UUID(pkg.uuid)].other, "version", "")
        else
            return ""
        end
    end
end


function pkg_path(pkg::PackageID, c::Pkg.Types.Context)
    if VERSION < v"1.1.0-DEV.857"
        if haskey(c.env.manifest, pkg.name)
            return get(c.env.manifest[pkg.name][1], "path", "")
        else
            return ""
        end
    else
        if !isempty(pkg.uuid) && haskey(c.env.manifest, Base.UUID(pkg.uuid))
            return get(c.env.manifest[Base.UUID(pkg.uuid)].other, "path", "")
        else
            return ""
        end
    end
end

function get_manifest(c::Pkg.Types.Context)
    out = PackageID[]
    if VERSION < v"1.1.0-DEV.857"
        for pkg in c.env.manifest
            push!(out, PackageID(pkg[1], get(pkg[2][1], "uuid", "")))
        end
    else
        for pkg in c.env.manifest
            push!(out, PackageID(pkg[2].name, string(pkg[1])))
        end
    end
    return out
end

function can_access(m::Module, s::Symbol)
    try
        return Base.eval(m, :($m.$s))
    catch
        return nothing
    end

end

function find_parent(c, uuid::String, out = Set{PackageID}())
    uuid = typeof(c.env.manifest).parameters[1](uuid)
    for pkg in c.env.manifest
        pkgname = VERSION < v"1.1.0-DEV.857" ? pkg[1] : pkg[2].name
        pkguuid = VERSION < v"1.1.0-DEV.857" ? pkg[2][1]["uuid"] : string(pkg[1])
        if uuid in values(pkg_deps(PackageID(pkgname, pkguuid), c))
            if pkgname in keys(context_deps(c))
                push!(out, PackageID(pkgname, pkguuid))
            else
                find_parent(c, pkguuid, out)
            end
        end
    end
    return out
end

function getgithash(path::String)
    repo = LibGit2.GitRepo(path)
    LibGit2.GitHash(LibGit2.GitObject(repo, LibGit2.name(LibGit2.head(repo))))
end

function isgitrepo(path::String)
    try
        LibGit2.GitRepo(path)
        return true
    catch err
        return false
    end
end
