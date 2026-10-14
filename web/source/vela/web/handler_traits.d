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
import vela.web.numtext : itoa;
import vela.http.utf8 : validUtf8;
import vela.web.convert;
import vela.web.json;
import vela.web.cookies : cookie;
import vela.web.models : Query, Form, isQueryModel, isFormModel, bindModel, bindFormBody, modelError;
import vela.web.stream : Stream, EventStream, isStreamReturn, runStream;

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
    || isWithStatus!R || isStreamReturn!R || is(R == struct) || is(R == U[], U) || is(R == V[K], V, K) && is(K == string)
    || isScalar!R;

/// True when the handler is `@safe` or `@trusted` (never plain `@system`).
/// Only enforced with `-version=VelaStrictSafe` (dub: `versions "VelaStrictSafe"`).
private bool isSafeHandler(alias fn)()
{
    foreach (a; __traits(getFunctionAttributes, fn))
        if (a == "@safe" || a == "@trusted")
            return true;
    return false;
}

version (VelaStrictSafe)
    private enum strictSafe = true;
else
    private enum strictSafe = false;

template handlerError(Method method, string path, alias fn, string file, size_t line)
{
    enum string head = file ~ "(" ~ ctNum(line) ~ "): vela: handler '"
        ~ __traits(identifier, fn) ~ "' in " ~ methodName(method) ~ " " ~ path ~ ": ";

    static if (__traits(isTemplate, fn) || !is(typeof(fn)))
        enum handlerError = head ~ "the handler has no concrete type. If it is a lambda, "
            ~ "declare the parameter types: (int id) => ...";
    else static if (strictSafe && !isSafeHandler!fn)
        enum handlerError = head ~ "is not @safe (VelaStrictSafe is on). Mark it @safe (or put `@safe:` at the top of the module) "
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
                    static if (isQueryModel!T)
                    {
                        enum merr = modelError!(typeof(T.value));
                        static if (merr.length)
                            return head ~ bad ~ "is Query!" ~ typeof(T.value).stringof ~ ": " ~ merr;
                    }
                    else static if (isFormModel!T)
                    {
                        bodies++;
                        if (method == Method.GET || method == Method.HEAD)
                            return head ~ bad ~ "is a Form, but " ~ methodName(method) ~ " has no body; use POST, PUT or PATCH";
                        enum merr = modelError!(typeof(T.value), true);
                        static if (merr.length)
                            return head ~ bad ~ "is Form!" ~ typeof(T.value).stringof ~ ": " ~ merr;
                    }
                    else static if (isJsonBody!T || is(T == Optional!(JsonBody!U), U))
                    {
                        bodies++;
                        if (method == Method.GET || method == Method.HEAD)
                            return head ~ bad ~ "is JsonBody, but " ~ methodName(method)
                                ~ " has no body; use POST, PUT or PATCH";
                    }
                    else static if (is(T == Optional!U, U))
                    {
                        static if (!(isScalar!U || isHeader!U || isCookie!U))
                            return head ~ bad ~ "is Optional!(" ~ U.stringof ~ "); Optional accepts "
                                ~ "a scalar, Header!\"Name\", Cookie!\"name\" or JsonBody!T";
                    }
                    else static if (is(T == U[], U) && !isScalar!T && !isScalarList!T)
                        return head ~ bad ~ "is a list of '" ~ U.stringof ~ "'; query lists hold scalars (int, string, enum...)";
                    else static if (!(is(T == Context) || isLocal!T || isHeader!T || isCookie!T || isClientIp!T || isScalar!T || isScalarList!T))
                        return head ~ bad ~ "has type '" ~ T.stringof ~ "', which vela cannot extract. "
                            ~ "Use a scalar (int, string, enum...), JsonBody!T, Header!\"Name\", Cookie!\"name\", Local!T, ClientIp, Optional!T or Context";
                }
            }}

            foreach (k, u; used)
                if (!u)
                    return head ~ "the route declares {" ~ info.params[k] ~ "}, but the function has no "
                        ~ "parameter named '" ~ info.params[k] ~ "'";
            if (bodies > 1)
                return head ~ "more than one body parameter (JsonBody or Form); merge the fields into a single DTO";

            static if (is(typeof(fn) R == return))
            {
                static if (!isSupportedReturn!R)
                    return head ~ "the return type '" ~ R.stringof ~ "' is not supported. Return void, "
                        ~ "string, a struct/array (JSON), WithStatus!T, Response, Stream or EventStream";
                enum st = successStatus!fn;
                static if (st != 0)
                {
                    if (st < 100 || st > 599)
                        return head ~ "@status(" ~ itoa(st) ~ ") is not an HTTP status; use a code from 100 to 599";
                    if (st == 204 && !is(R == void))
                        return head ~ "@status(204) means a response with no body, but the handler returns '"
                            ~ R.stringof ~ "'; return void";
                }
            }
            static foreach (a; __traits(getAttributes, fn))
                static if (is(typeof(a) == responds))
                {
                    if (a.code < 100 || a.code > 599)
                        return head ~ "@responds(" ~ itoa(a.code) ~ ", ...) is not an HTTP status; use a code from 100 to 599";
                }
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
            else static if (is(T == ClientIp))
                args[i].value = ctx.clientIp();
            else static if (isScalarList!T)
            {
                // ?tag=a&tag=b -> ["a", "b"]; absent -> the declared default, or an empty list (not an error)
                alias E = typeof(args[i][0]);
                size_t count;
                foreach (raw; ctx.request.queryValues(pname))
                {
                    E e;
                    if (bindListItem(ctx, raw, pname, count, e))
                        args[i] ~= e;
                    count++;
                }
                static if (is(typeof(((P[i .. i + 1] __a) => __a[0])())))
                    if (count == 0)
                        args[i] = ((P[i .. i + 1] __a) => __a[0])();
            }
            else static if (is(T == Local!U, U))
            {
                auto lp = ctx.locals.find!U();
                if (lp is null)
                    throw new Exception("Local!" ~ U.stringof ~ " missing: no middleware called ctx.locals.set(" ~ U.stringof ~ ")");
                args[i].value = *lp;
            }
            else static if (isQueryModel!T)
                bindModel(ctx, "query", ctx.request.query, args[i].value);
            else static if (isFormModel!T)
                bindFormBody(ctx, args[i].value);
            else static if (is(T == JsonBody!U, U))
                bindBody(ctx, args[i].value);
            else static if (is(T == Cookie!c, string c))
            {
                auto cv = ctx.cookie(c);
                if (cv is null)
                    ctx.errors.add("cookie", c, "missing", "Field required");
                else
                    args[i].value = cv.idup;
            }
            else static if (is(T == Header!n, string n))
            {
                auto hv = ctx.request.header(n);
                if (hv is null)
                    ctx.errors.add("header", n, "missing", "Field required");
                else
                    args[i].value = hv.idup;
            }
            else static if (is(T == Optional!U, U))
            {
                static if (is(U == Header!n, string n))
                {
                    auto hv = ctx.request.header(n);
                    if (hv !is null)
                        args[i] = T(U(hv.idup));
                }
                else static if (is(U == Cookie!c, string c))
                {
                    auto cv = ctx.cookie(c);
                    if (cv !is null)
                        args[i] = T(U(cv.idup));
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
                        ctx.errors.add("query", pname, "missing", "Field required");
                }
            }
        }}

        if (ctx.errors.any)
            return writeValidationErrors(ctx);

        static if (Self.length)
            enum call = "__traits(child, self[0], fn)(args)";
        else
            enum call = "fn(args)";

        // @trusted: the one place where the user's handler is called from @safe framework code.
        // A @safe handler is still checked by the compiler; a @system one is its author's responsibility.
        // (the return type comes from typeof(fn), not from a probe lambda: older compilers turn `args`
        // into a GC closure variable because a lambda mentions it, even inside typeof)
        static if (is(typeof(fn) R == return) && is(R == void))
        {
            () @trusted { mixin(call ~ ";"); }();
            ctx.response.status = successStatus!fn ? successStatus!fn : 204;
        }
        else
        {
            auto result = () @trusted { return mixin(call); }();
            // a streamed body runs inside writeResult, so its status must be set before it starts
            static if (successStatus!fn != 0 && isStreamReturn!(typeof(result)))
                ctx.response.status = successStatus!fn;
            writeResult(ctx, result);
            // @status applies unless the handler chose its own status (WithStatus, Response)
            static if (successStatus!fn != 0 && !isStreamReturn!(typeof(result))
                && !(is(typeof(result) == Response) || isWithStatus!(typeof(result))))
                ctx.response.status = successStatus!fn;
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
        ctx.errors.add(loc, name, "percent_encoding", "invalid percent-encoding");
        return false;
    }
    static if (is(T == string) || is(T == const(char)[]))
    {
        if (!validUtf8(text))
        {
            ctx.errors.add(loc, name, "string_unicode", "invalid UTF-8");
            return false;
        }
    }
    if (!parseScalarText(text, dest))
    {
        ctx.errors.add(loc, name, parseErrorType!T, parseErrorMsg!T);
        return false;
    }
    return true;
}

/// One element of a query list; errors carry its position: `["query","ids",1]`.
private bool bindListItem(T)(Context ctx, const(char)[] raw, string name, size_t index, ref T dest)
{
    const(char)[] text;
    if (!percentDecode(raw, true, text))
    {
        ctx.errors.addIndexed("query", name, index, "percent_encoding", "invalid percent-encoding");
        return false;
    }
    static if (is(T == string) || is(T == const(char)[]))
    {
        if (!validUtf8(text))
        {
            ctx.errors.addIndexed("query", name, index, "string_unicode", "invalid UTF-8");
            return false;
        }
    }
    if (!parseScalarText(text, dest))
    {
        ctx.errors.addIndexed("query", name, index, parseErrorType!T, parseErrorMsg!T);
        return false;
    }
    return true;
}

private bool bindBody(T)(Context ctx, ref T dest)
{
    if (ctx.request.body.length == 0)
    {
        ctx.errors.add("body", "", "missing", "JSON body required");
        return false;
    }
    return decodeJson(cast(const(char)[]) ctx.request.body, dest, ctx.errors);
}

/// 422 in FastAPI/Pydantic v2 format: {"detail":[{"type":"missing","loc":["query","limit"],"msg":"Field required"}]}
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
        o.put(`{"type":`);
        writeJsonString(*o, e.type);
        o.put(`,"loc":[`);
        writeJsonString(*o, e.location);
        if (e.locJson.length)
        {
            o.put(',');
            o.put(e.locJson); // already rendered JSON
        }
        o.put(`],"msg":`);
        writeJsonString(*o, e.message);
        o.put('}');
    }
    if (ctx.errors.dropped)
    {
        if (ctx.errors.count)
            o.put(',');
        o.put(`{"type":"too_many_errors","loc":[],"msg":"`);
        o.putUint(ctx.errors.dropped);
        o.put(` more errors not shown"}`);
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
            ctx.response.addHeader(h.name, h.value); // add, not set: two Set-Cookie must both survive
    }
    else static if (is(R == WithStatus!U, U))
    {
        static if (isStreamReturn!U)
        {
            ctx.response.status = r.status; // before the body runs: after the commit it could not change
            writeResult(ctx, r.value);
        }
        else
        {
            writeResult(ctx, r.value);
            ctx.response.status = r.status;
        }
    }
    else static if (isStreamReturn!R)
        runStream(ctx, r);
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
