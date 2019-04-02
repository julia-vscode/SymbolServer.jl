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
    string(Docs.doc(x))
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

function load_module(m, pkg, depot, out)
    out.doc = string(Docs.doc(m))
    out.exported = Set{String}(string.(names(m)))
    if haskey(depot["manifest"], pkg_uuid_or_name(pkg))
        entries = depot["manifest"][pkg_uuid_or_name(pkg)]
        # In julia 1.0 entries is an Array of Dicts, in 1.1+ it's a PackageEntry
        isa(entries, Array) || (entries = [entries])
        for entry in entries
            uuid = isa(entry, Dict) ? entry["uuid"] : string(entry.other["uuid"])
            if uuid == pkg_uuid(pkg)
                deps = isa(entry, Dict) ? get(entry, "deps", []) : entry.deps
                for dep in deps
                    try
                        depm = getfield(m, Symbol(pkg_name(dep)))
                        if !haskey(depot["packages"], pkg_uuid(dep))
                            depot["packages"][pkg_uuid(dep)] = ModuleStore(pkg_name(dep))
                            load_module(depm, dep, depot, depot["packages"][pkg_uuid(dep)])
                            out.vals[pkg_name(dep)] = pkg_name(dep)
                        else
                            out.vals[pkg_name(dep)] = pkg_name(dep)
                        end
                        # the above make reference to the name of the module, may have to change to uuid
                    catch err
                    end
                end
            end
        end
    end
    for n in names(m, all = true)
        !isdefined(m, n) && continue
        startswith(string(n), "#") && continue
        if Base.isdeprecated(m, n)
        else
            x = getfield(m, n)
            if x isa Function
                out.vals[String(n)] = FunctionStore(read_methods(x), _getdoc(x))
            elseif x isa DataType
                t, p = collect_params(x)
                if t.abstract
                    out.vals[String(n)] = abstractStore(string.(p), _getdoc(x))
                elseif t.isbitstype
                        out.vals[String(n)] = primitiveStore(string.(p), _getdoc(x))
                elseif !(isempty(t.types) || Base.isvatuple(t))
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
                    load_module(x, pkg, depot, out.vals[String(n)])
                end
            else
                out.vals[String(n)] = genericStore(string(typeof(x)), [], _getdoc(x))
            end
        end
    end
    out
end

function import_package(pkg::Pkg.Types.PackageEntry, depot)
    depot["packages"][pkg_uuid(pkg)] = ModuleStore(pkg_name(pkg))
    depot["packages"][pkg_uuid(pkg)].ver = pkg_ver(pkg)
    if pkg.path isa String && isdir(pkg.path)
        depot["packages"][pkg_uuid(pkg)].sha = get_dir_sha(pkg.path)
    end
    try
        Main.eval(:(import $(Symbol(pkg_name(pkg)))))
        m = getfield(Main, Symbol(pkg_name(pkg)))
        load_module(m, pkg_name(pkg) => pkg_uuid(pkg), depot, depot["packages"][pkg_uuid(pkg)])
    catch err
    end
    return depot["packages"][pkg_uuid(pkg)]
end

function load_core()
    c = Pkg.Types.Context()
    depot = create_depot(c, Dict{String,Any}("Base" => ModuleStore("Base"), "Core" => ModuleStore("Core")))

    load_module(Base, "Base"=>"Base", depot, depot["packages"]["Base"])
    load_module(Core, "Core"=>"Core", depot, depot["packages"]["Core"])
    push!(depot["packages"]["Base"].exported, "include")
    # Add special case macros
    depot["packages"]["Base"].vals["@."] = depot["packages"]["Base"].vals["@__dot__"]
    push!(depot["packages"]["Base"].exported, "@.")

    return depot
end

function create_depot(c, packages)
    return Dict(
        "manifest" => Dict(string(uuid)=>pkg for (uuid,pkg) in c.env.manifest),
        "installed" => (VERSION < v"1.1.0-DEV.857" ? c.env.project["deps"] : Dict(name=>string(uuid) for (name,uuid) in c.env.project.deps)),
        "packages" => packages)
end

function save_store_to_disc(store, file)
    io = open(file, "w")
    serialize(io, store)
    close(io)
end

pkg_name(pkg::Pkg.Types.PackageEntry) = pkg.name
pkg_uuid(pkg::Pkg.Types.PackageEntry) = pkg.other["uuid"]
pkg_ver(pkg::Pkg.Types.PackageEntry) = haskey(pkg.other, "version") ? pkg.other["version"] : ""

pkg_name(pkg) = first(pkg)
pkg_uuid(pkg) = string(last(pkg))
pkg_uuid_or_name(pkg) = VERSION < v"1.1.0-DEV.857" ? pkg_name(pkg) : pkg_uuid(pkg)

function get_dir_sha(dir::String)
    sha = zeros(UInt8, 32)
    for (root, dirs, files) in walkdir(dir)
        for file in files
            if endswith(file, ".jl")
                s1 = open(joinpath(root, file)) do f
                    sha2_256(f)
                end
                sha .+= s1
            end
        end
    end
    return sha
end
