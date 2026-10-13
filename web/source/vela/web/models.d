/// `Query!T` and `Form!T`: a struct bound from a query string or an `application/x-www-form-urlencoded` body, field by
/// field, by name.
///
///     struct Filters { string q; @jsonKey("page_size") int pageSize = 20; Optional!Sort sort; string[] tag; }
///     Page list(Query!Filters f) { ... f.pageSize ... }
///
/// Rules (one binder serves both):
///  - the external name of a field is its `@jsonKey`, else its name;
///  - a field is optional if it is an `Optional!X`, a list, marked `@optional`, or has an initializer that is not the
///    type's default (`int pageSize = 20`); anything else is required (`missing`);
///  - a scalar takes the first value of its key, a list takes every value (`?tag=a&tag=b`);
///  - fields are numbers, bool, enums, text, text types (`vela.http.texttype`), or `Optional`/lists of those;
///  - the validation attributes (`@minLength`, `@inRange`...) apply, with the same error format as a JSON body.
module vela.web.models;

@safe:

import vela.http.types : QueryValues;
import vela.http.utf8 : validUtf8;
import vela.web.context : Context;
import vela.web.convert : percentDecode, parseScalarText, parseErrorType, parseErrorMsg;
import vela.web.dto;
import vela.web.params : Optional, isScalar, isScalarList;

/// A struct bound from the query string.
struct Query(T)
{
    T value;
    alias value this;
}

/// A struct bound from a form body (`application/x-www-form-urlencoded`).
struct Form(T)
{
    T value;
    alias value this;
}

/// Why `T` cannot be a `Query!T`/`Form!T`: "" when it can. One line, for `handlerError`.
string modelError(T)()
{
    static if (!is(T == struct))
        return "'" ~ T.stringof ~ "' is not a struct";
    else
    {
        string e;
        static foreach (i; 0 .. T.tupleof.length)
        {
            static if (!hasUda!(T, i, jsonIgnore))
            {
                static if (!(isScalar!(typeof(T.tupleof[i])) || isScalarList!(typeof(T.tupleof[i]))
                    || isOptionalScalar!(typeof(T.tupleof[i]))))
                {
                    if (e.length == 0)
                        e = "field '" ~ __traits(identifier, T.tupleof[i]) ~ "' of " ~ T.stringof ~ " is "
                            ~ typeof(T.tupleof[i]).stringof ~ "; fields must be scalars (int, string, enum, bool...), "
                            ~ "text types, Optional of those, or lists of scalars";
                }
            }
        }
        return e;
    }
}

enum isOptionalScalar(F) = is(F == Optional!U, U) && isScalar!U;
enum isQueryModel(T) = is(T == Query!U, U);
enum isFormModel(T) = is(T == Form!U, U);

/// A scalar field is optional when it has a non-default initializer or `@optional` (lists and Optionals always are).
template modelFieldOptional(T, size_t i)
{
    alias F = typeof(T.tupleof[i]);
    enum modelFieldOptional = isScalarList!F || isOptionalScalar!F || isOptionalField!(T, i);
}

/// Binds `dest` from `source` (a query string or a form body). Errors go to `ctx.errors` with `location` ("query"/"body").
/// Returns false if any field failed.
bool bindModel(T)(Context ctx, string location, const(char)[] source, ref T dest)
{
    immutable before = ctx.errors.count + ctx.errors.dropped;
    FieldPath path;
    path.location = location;
    static foreach (i; 0 .. T.tupleof.length)
    {
        static if (!hasUda!(T, i, jsonIgnore))
        {{
            alias F = typeof(T.tupleof[i]);
            enum name = jsonKeyOf!(T, i);
            immutable mark = path.pushKey(name);
            static if (isScalarList!F)
            {
                alias E = typeof(dest.tupleof[i][0]);
                size_t n;
                bool any;
                foreach (raw; QueryValues(source, name))
                {
                    any = true;
                    E e;
                    immutable m2 = path.pushIndex(n++);
                    if (readOne(path, ctx, raw, e))
                        dest.tupleof[i] ~= e;
                    path.pop(m2);
                }
                if (any)
                    validateField!(T, i)(dest.tupleof[i], ctx.errors, path);
            }
            else static if (isOptionalScalar!F)
            {
                alias U = typeof(dest.tupleof[i].get());
                foreach (raw; QueryValues(source, name))
                {
                    U e;
                    if (readOne(path, ctx, raw, e))
                    {
                        dest.tupleof[i] = F(e);
                        validateField!(T, i)(e, ctx.errors, path);
                    }
                    break; // the first value
                }
            }
            else
            {
                bool seen;
                foreach (raw; QueryValues(source, name))
                {
                    seen = true;
                    F e;
                    if (readOne(path, ctx, raw, e))
                    {
                        dest.tupleof[i] = e;
                        validateField!(T, i)(e, ctx.errors, path);
                    }
                    break;
                }
                static if (!isOptionalField!(T, i))
                    if (!seen)
                        ctx.errors.addPath(path, "missing", "Field required");
            }
            path.pop(mark);
        }}
    }
    return ctx.errors.count + ctx.errors.dropped == before;
}

/// A scalar field is optional when it has a non-default initializer or `@optional`.
template isOptionalField(T, size_t i)
{
    enum isOptionalField = hasUda!(T, i, optional) || () {
        alias F = typeof(T.tupleof[i]);
        static if (is(typeof(T.init.tupleof[i] != F.init)))
            return T.init.tupleof[i] != F.init;
        else
            return false;
    }();
}

private bool readOne(F)(ref const FieldPath path, Context ctx, const(char)[] raw, ref F dest)
{
    const(char)[] text;
    if (!percentDecode(raw, true, text))
    {
        ctx.errors.addPath(path, "percent_encoding", "invalid percent-encoding");
        return false;
    }
    static if (is(F == string) || is(F == const(char)[]))
    {
        if (!validUtf8(text))
        {
            ctx.errors.addPath(path, "string_unicode", "invalid UTF-8");
            return false;
        }
    }
    if (!parseScalarText(text, dest))
    {
        ctx.errors.addPath(path, parseErrorType!F, parseErrorMsg!F);
        return false;
    }
    return true;
}
