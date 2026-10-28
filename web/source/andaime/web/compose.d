/// `construct!T(adapters)`: the composition root without the hand-written `new` lines. It reads the constructor of `T`,
/// finds each parameter's value by type in a struct of adapters (and in extra arguments), and builds a parameter that
/// is a concrete class the same way. Everything is resolved at compile time: no container, no reflection at run time,
/// and a missing or ambiguous value is a one-line compile error naming the class and the parameter.
///
///     struct Adapters { UnitOfWork uow; CompanyRepository companies; Clock clock; }
///     app.mount(construct!CompanyController(a));                  // its use cases are built from `a` too
///     auto login = construct!Login(a, jwtSecret, 15.minutes);     // values that are not ports: extra arguments
module andaime.web.compose 2025;

@safe:

import andaime.web.numtext : ctNum;

/// A new `T` whose constructor parameters come from `extra` (an argument whose type is exactly the parameter's), from
/// `adapters` (the field whose type is exactly the parameter's) or, for a parameter that is a concrete class, from a new
/// instance built the same way. `T` has at most one constructor. A parameter with no value, or with two candidates in
/// the same place (two fields, or two extra arguments, of one type), fails to compile.
T construct(T, A, Extra...)(auto ref A adapters, auto ref Extra extra) if (is(T == class))
{
    // checked here, before anything deep is instantiated, so the error stays one line (see `handlerError`)
    enum err = constructError!(T, TypeList!(), A, Extra);
    static if (err.length)
        static assert(0, err);
    else
        return build!(T, A, Extra)(adapters, extra);
}

private struct TypeList(Ts...)
{
    alias types = Ts;
}

private enum bool isAggregate(A) = is(A == struct) || is(A == class);

private enum Source { extra, field, newInstance, missing, manyExtra, manyFields }

// Where a constructor parameter of type P gets its value: an extra argument first, then an adapters field, then a new
// instance when P is a concrete class.
private template sourceOf(P, A, Extra...)
{
    enum Source sourceOf = () {
        enum inExtra = countOf!(P, Extra);
        enum inFields = countOf!(P, typeof(A.tupleof));
        static if (inExtra > 1)
            return Source.manyExtra;
        else static if (inExtra == 1)
            return Source.extra;
        else static if (inFields > 1)
            return Source.manyFields;
        else static if (inFields == 1)
            return Source.field;
        else static if (is(P == class) && !__traits(isAbstractClass, P))
            return Source.newInstance;
        else
            return Source.missing;
    }();
}

private template countOf(P, Ts...)
{
    enum size_t countOf = () {
        size_t n;
        static foreach (T; Ts)
            static if (is(T == P))
                n++;
        return n;
    }();
}

private template anyIs(T, Ts...)
{
    enum bool anyIs = () {
        bool r;
        static foreach (S; Ts)
            static if (is(T == S))
                r = true;
        return r;
    }();
}

// The first problem with building T from A and Extra, or "". Seen = the classes being built, outermost first.
private template constructError(T, Seen, A, Extra...)
{
    enum string constructError = () {
        enum pre = "andaime: construct!" ~ T.stringof ~ ": ";
        static if (!isAggregate!A)
            return pre ~ "the adapters must be a struct (or class), not " ~ A.stringof;
        else static if (__traits(isAbstractClass, T))
            return pre ~ T.stringof ~ " is abstract; ask for a concrete class";
        else static if (anyIs!(T, Seen.types))
            return pre ~ "the constructor parameters form a cycle";
        else static if (!__traits(hasMember, T, "__ctor"))
            return "";
        else
        {
            alias ctors = __traits(getOverloads, T, "__ctor");
            static if (ctors.length != 1)
                return pre ~ T.stringof ~ " has several constructors; construct needs exactly one";
            else static if (is(typeof(ctors[0]) Params == __parameters))
            {
                string e;
                static foreach (i, P; Params)
                {{
                    enum where = pre ~ "parameter '" ~ __traits(identifier, Params[i .. i + 1]) ~ "' (" ~ P.stringof ~ ")";
                    enum src = sourceOf!(P, A, Extra);
                    static if (src == Source.manyExtra)
                        enum msg = where ~ " matches several extra arguments; pass one value of that type";
                    else static if (src == Source.manyFields)
                        enum msg = where ~ " matches several fields of " ~ A.stringof
                            ~ "; keep one field of that type or pass the value as an extra argument";
                    else static if (src == Source.missing)
                        enum msg = where ~ " has no value: add a field of that type to " ~ A.stringof
                            ~ " or pass it as an extra argument";
                    else static if (src == Source.newInstance)
                        enum msg = constructError!(P, TypeList!(Seen.types, T), A, Extra);
                    else
                        enum msg = "";
                    if (e.length == 0)
                        e = msg;
                }}
                return e;
            }
            else
                return "";
        }
    }();
}

// Only reached with `constructError` empty.
private T build(T, A, Extra...)(ref A adapters, ref Extra extra)
{
    static if (!__traits(hasMember, T, "__ctor"))
        return new T();
    else
    {
        alias ctors = __traits(getOverloads, T, "__ctor");
        static if (is(typeof(ctors[0]) Params == __parameters))
        {
            auto pick(size_t i)()
            {
                alias P = Params[i];
                enum src = sourceOf!(P, A, Extra);
                static if (src == Source.extra)
                {
                    static foreach (k, E; Extra)
                        static if (is(E == P))
                            return extra[k];
                }
                else static if (src == Source.field)
                {
                    static foreach (k, F; typeof(A.tupleof))
                        static if (is(F == P))
                            return adapters.tupleof[k];
                }
                else
                    return build!(P, A, Extra)(adapters, extra);
            }

            enum string call = () {
                string s;
                foreach (i; 0 .. Params.length)
                    s ~= (i ? "," : "") ~ "pick!" ~ ctNum(i) ~ "()";
                return "return new T(" ~ s ~ ");";
            }();
            mixin(call);
        }
    }
}
