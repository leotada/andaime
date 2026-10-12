/// Compile-time handler introspection.
///
/// For each registered route, `dispatch` generates (via shallow `static foreach`,
/// with no template recursion) the code that extracts each argument from the
/// request and calls the handler. `handlerError` validates the signature and returns
/// ONE line explaining what to fix, or "" if everything is fine.
///
/// Binding rules, in order:
///   1. parameter name appears as {name} in the route  -> path (scalar)
///   2. Context                                        -> the context itself
///      Local!T                                        -> value from ctx.locals (set by middleware)
///   3. JsonBody!T                                     -> decoded JSON body
///   4. Header!"Name"                                  -> required header
///   5. Optional!X (X = escalar, Header, JsonBody)     -> optional
///   6. scalar outside the route                       -> query (default => optional)
module vela.web.handler_traits;

@safe:

import vela.http.types;
import vela.web.context;
import vela.web.params;
import vela.web.dto : FieldErrors, ctNum;
import vela.web.convert;
import vela.web.json;

// =====================================================================
// Route pattern (CTFE)
// =====================================================================

struct RouteInfo
{
    string[] params;  /// names of the {params}, in order
    bool[] catchAll;  /// true for {*rest}
    string error;     /// syntax error, if any
}

RouteInfo parseRoute(string path) pure @safe
{
    RouteInfo info;
    if (path.length == 0 || path[0] != '/')
    {
        info.error = "route \"" ~ path ~ "\" must start with '/'";
        return info;
    }
    size_t i = 0;
    while (i < path.length)
    {
        if (path[i] == '{')
        {
            size_t j = i + 1;
            while (j < path.length && path[j] != '}' && path[j] != '/')
                j++;
            if (j == path.length || path[j] != '}')
            {
                info.error = "unclosed '{' in route \"" ~ path ~ "\"";
                return info;
            }
            string name = path[i + 1 .. j];
            bool rest = name.length && name[0] == '*';
            if (rest)
                name = name[1 .. $];
            if (name.length == 0)
            {
                info.error = "unnamed parameter in route \"" ~ path ~ "\"";
                return info;
            }
            foreach (p; info.params)
                if (p == name)
                {
                    info.error = "repeated parameter {" ~ name ~ "} in route \"" ~ path ~ "\"";
                    return info;
                }
            info.params ~= name;
            info.catchAll ~= rest;
            i = j + 1;
        }
        else
            i++;
    }
    if (info.params.length > PathParams.max)
        info.error = "route \"" ~ path ~ "\" has more than " ~ ctNum(PathParams.max) ~ " parameters";
    return info;
}

ptrdiff_t indexOfName(const string[] names, string name) pure nothrow @nogc @safe
{
    foreach (i, n; names)
        if (n == name)
            return i;
    return -1;
}

// =====================================================================
// Signature validation: one error line, or ""
// =====================================================================

/// Accepted return types.
enum isSupportedReturn(R) = is(R == void) || is(R : const(char)[]) || is(R == Response)
    || isWithStatus!R || is(R == struct) || is(R == U[], U) || isScalar!R;

/// True when the handler is `@safe` or `@trusted` (never plain `@system`).
private bool isSafeHandler(alias fn)()
{
    foreach (a; __traits(getFunctionAttributes, fn))
        if (a == "@safe" || a == "@trusted")
            return true;
    return false;
}

template handlerError(Method method, string path, alias fn, string file, size_t line)
{
    enum string head = file ~ "(" ~ ctNum(line) ~ "): vela: handler '"
        ~ __traits(identifier, fn) ~ "' in " ~ methodName(method) ~ " " ~ path ~ ": ";

    static if (__traits(isTemplate, fn) || !is(typeof(fn)))
        enum handlerError = head ~ "the handler has no concrete type. If it is a lambda, "
            ~ "declare the parameter types: (int id) => ...";
    else static if (!isSafeHandler!fn)
        enum handlerError = head ~ "is not @safe. Mark it @safe (or put `@safe:` at the top of the module) "
            ~ "and wrap code that cannot be proven safe in @trusted";
    else static if (is(typeof(fn) P == __parameters))
    {
        enum handlerError = () {
            auto info = parseRoute(path);
            if (info.error.length)
                return head ~ info.error;
            auto used = new bool[info.params.length];
            size_t bodies = 0;

            static foreach (i; 0 .. P.length)
            {{
                alias T = P[i];
                enum pname = __traits(identifier, P[i .. i + 1]);
                enum stc = __traits(getParameterStorageClasses, fn, i);
                enum bad = "parameter '" ~ pname ~ "' ";
                foreach (s; stc)
                    if (s == "ref" || s == "out" || s == "lazy")
                        return head ~ bad ~ "cannot be '" ~ s ~ "'; take it by value";

                immutable ri = indexOfName(info.params, pname);
                if (ri >= 0)
                {
                    used[ri] = true;
                    if (!isScalar!T)
                        return head ~ bad ~ "comes from the route ({" ~ pname ~ "}) and must be a scalar "
                            ~ "(int, long, string, bool, enum...), but it is '" ~ T.stringof ~ "'";
                    if (info.catchAll[ri] && !is(T == string) && !is(T == const(char)[]))
                        return head ~ bad ~ "captures {*" ~ pname ~ "} and must be string or const(char)[]";
                }
                else
                {
                    static if (isJsonBody!T || is(T == Optional!(JsonBody!U), U))
                    {
                        bodies++;
                        if (method == Method.GET || method == Method.HEAD)
                            return head ~ bad ~ "is JsonBody, but " ~ methodName(method)
                                ~ " has no body; use POST, PUT or PATCH";
                    }
                    else static if (is(T == Optional!U, U))
                    {
                        static if (!(isScalar!U || isHeader!U))
                            return head ~ bad ~ "is Optional!(" ~ U.stringof ~ "); Optional accepts "
                                ~ "a scalar, Header!\"Name\" or JsonBody!T";
                    }
                    else static if (!(is(T == Context) || isLocal!T || isHeader!T || isScalar!T))
                        return head ~ bad ~ "has type '" ~ T.stringof ~ "', which vela cannot extract. "
                            ~ "Use a scalar (int, string, enum...), JsonBody!T, Header!\"Name\", Local!T, Optional!T or Context";
                }
            }}

            foreach (k, u; used)
                if (!u)
                    return head ~ "the route declares {" ~ info.params[k] ~ "}, but the function has no "
                        ~ "parameter named '" ~ info.params[k] ~ "'";
            if (bodies > 1)
                return head ~ "more than one JsonBody; merge the fields into a single DTO";

            static if (is(typeof(fn) R == return))
                static if (!isSupportedReturn!R)
                    return head ~ "the return type '" ~ R.stringof ~ "' is not supported. Return void, "
                        ~ "string, a struct/array (JSON), WithStatus!T or Response";
            return "";
        }();
    }
    else
        enum handlerError = head ~ "is not a function";
}

// =====================================================================
// Generated dispatch
// =====================================================================

/// Extracts the arguments from `ctx`, calls the handler and writes the response.
/// `self` (optional) is the controller instance for methods.
void dispatch(Method method, string path, alias fn, Self...)(Context ctx, Self self)
    if (Self.length <= 1)
{
    static if (is(typeof(fn) P == __parameters))
    {
        enum info = parseRoute(path);
        P args;

        static foreach (i; 0 .. P.length)
        {{
            alias T = P[i];
            enum pname = __traits(identifier, P[i .. i + 1]);
            enum ri = indexOfName(info.params, pname);

            static if (ri >= 0)
                bindText(ctx, ctx.params[ri], false, "path", pname, args[i]);
            else static if (is(T == Context))
                args[i] = ctx;
            else static if (is(T == Local!U, U))
            {
                auto lp = ctx.locals.find!U();
                if (lp is null)
                    throw new Exception("Local!" ~ U.stringof ~ " missing: no middleware called ctx.locals.set(" ~ U.stringof ~ ")");
                args[i].value = *lp;
            }
            else static if (is(T == JsonBody!U, U))
                bindBody(ctx, args[i].value);
            else static if (is(T == Header!n, string n))
            {
                auto hv = ctx.request.header(n);
                if (hv is null)
                    ctx.errors.add("header", n, "required header missing");
                else
                    args[i].value = hv;
            }
            else static if (is(T == Optional!U, U))
            {
                static if (is(U == Header!n, string n))
                {
                    auto hv = ctx.request.header(n);
                    if (hv !is null)
                        args[i] = T(U(hv));
                }
                else static if (is(U == JsonBody!V, V))
                {
                    if (ctx.request.body.length)
                    {
                        U tmp;
                        if (bindBody(ctx, tmp.value))
                            args[i] = T(tmp);
                    }
                }
                else
                {
                    const(char)[] raw;
                    if (ctx.request.rawQueryParam(pname, raw))
                    {
                        U tmp;
                        if (bindText(ctx, raw, true, "query", pname, tmp))
                            args[i] = T(tmp);
                    }
                }
            }
            else // scalar outside the route => query
            {
                const(char)[] raw;
                if (ctx.request.rawQueryParam(pname, raw))
                    bindText(ctx, raw, true, "query", pname, args[i]);
                else
                {
                    // default value declared in the signature (`int limit = 20`)
                    static if (is(typeof(((P[i .. i + 1] __a) => __a[0])())))
                        args[i] = ((P[i .. i + 1] __a) => __a[0])();
                    else
                        ctx.errors.add("query", pname, "required parameter missing");
                }
            }
        }}

        if (ctx.errors.any)
            return writeValidationErrors(ctx);

        static if (Self.length)
            enum call = "__traits(child, self[0], fn)(args)";
        else
            enum call = "fn(args)";

        static if (is(typeof(mixin(call)) == void))
        {
            mixin(call ~ ";");
            ctx.response.status = 204;
        }
        else
        {
            auto result = mixin(call);
            writeResult(ctx, result);
        }
    }
    else
        static assert(0, "vela: dispatch without a prior handlerError (internal bug)");
}

private bool bindText(T)(Context ctx, const(char)[] raw, bool plusIsSpace, string loc,
    string name, ref T dest)
{
    const(char)[] text;
    if (!percentDecode(raw, plusIsSpace, text))
    {
        ctx.errors.add(loc, name, "invalid % encoding");
        return false;
    }
    if (!parseScalarText(text, dest))
    {
        ctx.errors.add(loc, name, typeHint!T);
        return false;
    }
    return true;
}

private bool bindBody(T)(Context ctx, ref T dest)
{
    if (ctx.request.body.length == 0)
    {
        ctx.errors.add("body", "", "JSON body required");
        return false;
    }
    return decodeJson(cast(const(char)[]) ctx.request.body, dest, ctx.errors);
}

/// 422 in FastAPI format: {"detail":[{"loc":["query","limit"],"msg":"..."}]}
void writeValidationErrors(Context ctx)
{
    auto o = &ctx.response.body;
    ctx.response.status = 422;
    ctx.response.contentType = "application/json";
    o.clear();
    o.put(`{"detail":[`);
    foreach (k, ref e; ctx.errors.list)
    {
        if (k)
            o.put(',');
        o.put(`{"loc":[`);
        writeJsonString(*o, e.location);
        if (e.field.length)
        {
            o.put(',');
            writeJsonString(*o, e.field);
        }
        o.put(`],"msg":`);
        writeJsonString(*o, e.message);
        o.put('}');
    }
    o.put("]}");
}

/// Writes the value returned by the handler.
void writeResult(R)(Context ctx, ref R r)
{
    static if (is(R == Response))
    {
        ctx.response.status = r.status;
        ctx.response.contentType = r.contentType;
        ctx.response.body.put(r.body);
        foreach (ref h; r.headers)
            ctx.response.setHeader(h.name, h.value);
    }
    else static if (is(R == WithStatus!U, U))
    {
        writeResult(ctx, r.value);
        ctx.response.status = r.status;
    }
    else static if (is(R : const(char)[]))
    {
        ctx.response.contentType = "text/plain; charset=utf-8";
        ctx.response.body.put(r);
    }
    else
    {
        ctx.response.contentType = "application/json";
        writeJson(ctx.response.body, r);
    }
}
