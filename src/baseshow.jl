module BaseShow
# stdlibs/v1.3/REPL/src/docview.jl
using Markdown, REPL
_doc(obj::UnionAll) = _doc(Base.unwrap_unionall(obj))
_doc(object, sig::Type = Union{}) = _doc(Base.Docs.aliasof(object, typeof(object)), sig)
_doc(object, sig...)              = _doc(object, Tuple{sig...})

function _doc(binding::Base.Docs.Binding, sig::Type = Union{})
    if Base.Docs.defined(binding)
        result = Base.Docs.getdoc(Base.Docs.resolve(binding), sig)
        result === nothing || return result
    end
    results, groups = Base.Docs.DocStr[], Base.Docs.MultiDoc[]
    # Lookup `binding` and `sig` for matches in all modules of the docsystem.
    for mod in Base.Docs.modules
        dict = Base.Docs.meta(mod)
        if haskey(dict, binding)
            multidoc = dict[binding]
            push!(groups, multidoc)
            for msig in multidoc.order
                sig <: msig && push!(results, multidoc.docs[msig])
            end
        end
    end
    if isempty(groups)
        # When no `MultiDoc`s are found that match `binding` then we check whether `binding`
        # is an alias of some other `Binding`. When it is we then re-run `doc` with that
        # `Binding`, otherwise if it's not an alias then we generate a summary for the
        # `binding` and display that to the user instead.
        alias = Base.Docs.aliasof(binding)
        alias == binding ? _summarize(alias, sig) : _doc(alias, sig)
    else
        # There was at least one match for `binding` while searching. If there weren't any
        # matches for `sig` then we concatenate *all* the docs from the matching `Binding`s.
        if isempty(results)
            for group in groups, each in group.order
                push!(results, group.docs[each])
            end
        end
        # Get parsed docs and concatenate them.
        md = Base.Docs.catdoc(map(Base.Docs.parsedoc, results)...)
        # Save metadata in the generated markdown.
        if isa(md, Markdown.MD)
            md.meta[:results] = results
            md.meta[:binding] = binding
            md.meta[:typesig] = sig
        end
        return md
    end
end

function _summarize(binding::Base.Docs.Binding, sig)
    io = IOBuffer()
    println(io, "No documentation found.\n")
    if Base.Docs.defined(binding)
        _summarize(io, Base.Docs.resolve(binding), binding)
    else
        println(io, "Binding `", binding, "` does not exist.")
    end
    md = Markdown.parse(seekstart(io))
    # Save metadata in the generated markdown.
    md.meta[:results] = Base.Docs.DocStr[]
    md.meta[:binding] = binding
    md.meta[:typesig] = sig
    return md
end

function _summarize(io::IO, λ::Function, binding)
    kind = startswith(string(binding.var), '@') ? "macro" : "`Function`"
    println(io, "`", binding, "` is a ", kind, ".")
    # println(io, "```\n", methods(λ), "\n```")
    print(io, "```\n")
    _show_method_table(io, methods(λ))
    println(io, "\n```")
end

_summarize(io::IO, T::DataType, binding) = REPL.summarize(io, T, binding)
_summarize(io::IO, m::Module, binding) = REPL.summarize(io, m, binding)
_summarize(io::IO, @nospecialize(T), binding) = REPL.summarize(io, T, binding)

# base/show/methodshow.jl


function _show_method_table(io::IO, ms::Base.MethodList, max::Int=-1, header::Bool=true)
    mt = ms.mt
    name = mt.name
    hasname = isdefined(mt.module, name) &&
              typeof(getfield(mt.module, name)) <: Function
    if header
        Base.show_method_list_header(io, ms, str -> "\""*str*"\"")
    end
    kwtype = isdefined(mt, :kwsorter) ? typeof(mt.kwsorter) : nothing
    n = rest = 0
    local last

    resize!(Base.LAST_SHOWN_LINE_INFOS, 0)
    for meth in ms
        if max==-1 || n<max
            n += 1
            println(io)
            print(io, "[$n] ")
            _show(io, meth; kwtype=kwtype)
            file, line = meth.file, meth.line
            try
                file, line = Base.invokelatest(Base.methodloc_callback[], meth)
            catch
            end
            push!(Base.LAST_SHOWN_LINE_INFOS, (string(file), line))
        else
            rest += 1
            last = meth
        end
    end
    if rest > 0
        println(io)
        if rest == 1
            show(io, last; kwtype=kwtype)
        else
            print(io, "... $rest methods not shown")
            if hasname
                print(io, " (use methods($name) to see them all)")
            end
        end
    end
end

_show(io::IO, x) = Base.invokelatest(Base.show, io, x)
_show(io::IO, ms::Base.MethodList) = _show_method_table(io, ms)
_show(io::IO, mt::Core.MethodTable) = _show_method_table(io, Base.MethodList(mt))

function _show(io::IO, m::Method; kwtype::Union{DataType, Nothing}=nothing)
    tv, decls, file, line = _arg_decl_parts(m)
    sig = Base.unwrap_unionall(m.sig)
    ft0 = sig.parameters[1]
    ft = Base.unwrap_unionall(ft0)
    d1 = decls[1]
    if sig === Tuple
        # Builtin
        print(io, m.name, "(...) in ", m.module)
        return
    end
    if ft <: Function && isa(ft, DataType) &&
            isdefined(ft.name.module, ft.name.mt.name) &&
                # TODO: more accurate test? (tn.name === "#" name)
            ft0 === typeof(getfield(ft.name.module, ft.name.mt.name))
        print(io, ft.name.mt.name)
    elseif isa(ft, DataType) && ft.name === Type.body.name
        f = ft.parameters[1]
        if isa(f, DataType) && isempty(f.parameters)
            print(io, f)
        else
            print(io, "(", d1[1], "::", d1[2], ")")
        end
    else
        print(io, "(", d1[1], "::", d1[2], ")")
    end
    print(io, "(")
    join(io, String[isempty(d[2]) ? d[1] : d[1]*"::"*d[2] for d in decls[2:end]],
                 ", ", ", ")
    if kwtype !== nothing
        kwargs = Base.kwarg_decl(m, kwtype)
        if !isempty(kwargs)
            print(io, "; ")
            join(io, kwargs, ", ", ", ")
        end
    end
    print(io, ")")
    _show_method_params(io, tv)
    print(io, " in ", m.module)
    if line > 0
        try
            file, line = Base.invokelatest(Base.methodloc_callback[], m)
        catch
        end
        print(io, " at ", file, ":", line)
    end
end

function _arg_decl_parts(m::Method)
    tv = Any[]
    sig = m.sig
    while isa(sig, UnionAll)
        push!(tv, sig.var)
        sig = sig.body
    end
    file = m.file
    line = m.line
    argnames = Base.method_argnames(m)
    if length(argnames) >= m.nargs
        show_env = Base.ImmutableDict{Symbol, Any}()
        for t in tv
            show_env = Base.ImmutableDict(show_env, :unionall_env => t)
        end
        decls = Tuple{String,String}[_argtype_decl(show_env, argnames[i], sig, i, m.nargs, m.isva)
                    for i = 1:m.nargs]
    else
        decls = Tuple{String,String}[("", "") for i = 1:length(sig.parameters::Core.SimpleVector)]
    end
    return tv, decls, file, line
end

function _argtype_decl(env, n, sig::DataType, i::Int, nargs, isva::Bool) # -> (argname, argtype)
    t = sig.parameters[i]
    if i == nargs && isva && !Base.isvarargtype(t)
        t = Vararg{t,length(sig.parameters)-nargs+1}
    end
    if isa(n,Expr)
        n = n.args[1]  # handle n::T in arg list
    end
    s = string(n)
    i = findfirst(isequal('#'), s)
    if i !== nothing
        s = s[1:i-1]
    end
    if t === Any && !isempty(s)
        return s, ""
    end
    if Base.isvarargtype(t)
        v1, v2 = nothing, nothing
        if isa(t, UnionAll)
            v1 = t.var
            t = t.body
            if isa(t, UnionAll)
                v2 = t.var
                t = t.body
            end
        end
        ut = Base.unwrap_unionall(t)
        tt, tn = ut.parameters[1], ut.parameters[2]
        if isa(tn, TypeVar) && (tn === v1 || tn === v2)
            if tt === Any || (isa(tt, TypeVar) && (tt === v1 || tt === v2))
                return string(s, "..."), ""
            else
                return s, _string_with_env(env, tt) * "..."
            end
        end
        return s, _string_with_env(env, "Vararg{", tt, ",", tn, "}")
    end
    return s, _string_with_env(env, t)
end

@static if isdefined(Base, :_str_sizehint)
    _str_sizehint = Base._str_sizehint
else
    _str_sizehint = Base.tostr_sizehint
end

function _string_with_env(env, xs...)
    if isempty(xs)
        return ""
    end
    siz::Int = 0
    for x in xs
        siz += _str_sizehint(x)
    end
    # specialized for performance reasons
    s = IOBuffer(sizehint=siz)
    env_io = IOContext(s, env)
    for x in xs
        _show(env_io, x)
    end
    String(resize!(s.data, s.size))
end

function _show_method_params(io::IO, tv)
    if !isempty(tv)
        print(io, " where ")
        if length(tv) == 1
            _show(io, tv[1])
        else
            print(io, "{")
            for i = 1:length(tv)
                if i > 1
                    print(io, ", ")
                end
                x = tv[i]
                _show(io, x)
                io = IOContext(io, :unionall_env => x)
            end
            print(io, "}")
        end
    end
end


_show(io::IO, ::Core.TypeofBottom) = print(io, "Union{}")
function _show(io::IO, @nospecialize(x::Type))
    if x isa DataType
        _show_datatype(io, x)
        return
    elseif x isa Union
        print(io, "Union")
        _show_delim_array(io, Base.uniontypes(x), '{', ',', '}', false)
        return
    end
    x::UnionAll

    if Base.print_without_params(x)
        return _show(io, Base.unwrap_unionall(x).name)
    end

    if x.var.name === :_ || Base.io_has_tvar_name(io, x.var.name, x)
        counter = 1
        while true
            newname = Symbol(x.var.name, counter)
            if !Base.io_has_tvar_name(io, newname, x)
                newtv = TypeVar(newname, x.var.lb, x.var.ub)
                x = UnionAll(newtv, x{newtv})
                break
            end
            counter += 1
        end
    end

    _show(IOContext(io, :unionall_env => x.var), x.body)
    print(io, " where ")
    _show(io, x.var)
end

function _show(io::IO, tv::TypeVar)
    # If we are in the `unionall_env`, the type-variable is bound
    # and the type constraints are already printed.
    # We don't need to print it again.
    # Otherwise, the lower bound should be printed if it is not `Bottom`
    # and the upper bound should be printed if it is not `Any`.
    in_env = (:unionall_env => tv) in io
    function show_bound(io::IO, @nospecialize(b))
        parens = isa(b,UnionAll) && !Base.print_without_params(b)
        parens && print(io, "(")
        _show(io, b)
        parens && print(io, ")")
    end
    lb, ub = tv.lb, tv.ub
    if !in_env && lb !== Base.Bottom
        if ub === Any
            write(io, tv.name)
            print(io, ">:")
            show_bound(io, lb)
        else
            show_bound(io, lb)
            print(io, "<:")
            write(io, tv.name)
        end
    else
        write(io, tv.name)
    end
    if !in_env && ub !== Any
        print(io, "<:")
        show_bound(io, ub)
    end
    nothing
end

function _show_datatype(io::IO, x::DataType)
    istuple = x.name === Tuple.name
    if (!isempty(x.parameters) || istuple) && x !== Tuple
        n = length(x.parameters)::Int

        # Print homogeneous tuples with more than 3 elements compactly as NTuple{N, T}
        if istuple && n > 3 && all(i -> (x.parameters[1] === i), x.parameters)
            # print(io, "NTuple{", n, ',', x.parameters[1], "}")
            print(io, "NTuple{", n, ',')
            show(io, x.parameters[1])
            print(io, "}")
        else
            _show_type_name(io, x.name)
            # Do not print the type parameters for the primary type if we are
            # printing a method signature or type parameter.
            # Always print the type parameter if we are printing the type directly
            # since this information is still useful.
            print(io, '{')
            for (i, p) in enumerate(x.parameters)
                _show(io, p)
                i < n && print(io, ',')
            end
            print(io, '}')
        end
    else
        _show_type_name(io, x.name)
    end
end

function _show_type_name(io::IO, tn::Core.TypeName)
    if tn === UnionAll.name
        # by coincidence, `typeof(Type)` is a valid representation of the UnionAll type.
        # intercept this case and print `UnionAll` instead.
        return print(io, "UnionAll")
    end
    globname = isdefined(tn, :mt) ? tn.mt.name : nothing
    globfunc = false
    if globname !== nothing
        globname_str = string(globname::Symbol)
        if ('#' ∉ globname_str && '@' ∉ globname_str && isdefined(tn, :module) &&
                Base.isbindingresolved(tn.module, globname) && isdefined(tn.module, globname) &&
                isconcretetype(tn.wrapper) && isa(getfield(tn.module, globname), tn.wrapper))
            globfunc = true
        end
    end
    sym = (globfunc ? globname : tn.name)::Symbol
    globfunc && print(io, "typeof(")
    quo = false
    if !get(io, :compact, false)
        # Print module prefix unless type is visible from module passed to
        # IOContext If :module is not set, default to Main. nothing can be used
        # to force printing prefix
        from = get(io, :module, Main)
        if isdefined(tn, :module) && (from === nothing || !Base.isvisible(sym, tn.module, from))
            show(io, tn.module)
            print(io, ".")
            if globfunc && !Base.is_id_start_char(first(string(sym)))
                print(io, ':')
                if sym in Base.quoted_syms
                    print(io, '(')
                    quo = true
                end
            end
        end
    end
    Base.show_sym(io, sym)
    quo      && print(io, ")")
    globfunc && print(io, ")")
end

function _show_delim_array(io::IO, itr, op, delim, cl, delim_one, i1=1, n=typemax(Int))
    print(io, op)
    if !Base.show_circular(io, itr)
        recur_io = IOContext(io, :SHOWN_SET => itr)
        y = iterate(itr)
        first = true
        i0 = i1-1
        while i1 > 1 && y !== nothing
            y = iterate(itr, y[2])
            i1 -= 1
        end
        if y !== nothing
            typeinfo = get(io, :typeinfo, Any)
            while true
                x = y[1]
                y = iterate(itr, y[2])
                _show(IOContext(recur_io, :typeinfo => itr isa typeinfo <: Tuple ?
                                             fieldtype(typeinfo, i1+i0) :
                                             typeinfo),
                     x)
                i1 += 1
                if y === nothing || i1 > n
                    delim_one && first && print(io, delim)
                    break
                end
                first = false
                print(io, delim)
                print(io, ' ')
            end
        end
    end
    print(io, cl)
end
end
