/// `App`: route registration, middlewares and the per-request entry point.
module vela.web.application;

@safe:

import vela.http.types;
import vela.http.ip : Cidr, parseCidr;
import vela.web.context;
import vela.web.params : HttpError;
import vela.web.dto : ValidationErrors;
import vela.web.numtext : itoa;
import vela.web.router;
import vela.web.handler_traits : handlerError, dispatch;
import vela.web.json : writeJsonString;
import vela.web.openapi;
import vela.web.response_check : checkResponse;
import vela.http.date : httpDate;

/// Route UDA for controller methods: `@Get("/users/{id}")`.
struct Route
{
    Method method;
    string path;
    bool websocket; /// `@Ws`: a GET that upgrades to a WebSocket
}

Route Get(string path) => Route(Method.GET, path);
Route Post(string path) => Route(Method.POST, path);
Route Put(string path) => Route(Method.PUT, path);
Route Patch(string path) => Route(Method.PATCH, path);
Route Delete(string path) => Route(Method.DELETE, path);
/// A WebSocket route on a controller method returning `WebSocket` (see `ws!`).
Route Ws(string path) => Route(Method.GET, path, true);

alias HandlerFn = void delegate(Context);

/// A handler written by the user (`onNotFound`); may be `@safe` or `@system`.
alias UserHandler = void delegate(Context) @system;

/// Called instead of the default handling when a handler or middleware throws.
/// Write the response into `ctx` (`ctx.text(...)`, `ctx.response.status = ...`).
alias ErrorHandler = void delegate(Context ctx, Exception e) @system;

/// Answers a request whose parameters failed to bind (see `App.onValidationError`). Read the errors from `errors`
/// and write the response into `ctx`.
alias ValidationErrorHandler = void delegate(Context ctx, ValidationErrors errors) @system;

// @trusted: single entry points for user callbacks (their safety is the user's business)
private void callUser(UserHandler h, Context ctx) @trusted { h(ctx); }
private void callUser(ErrorHandler h, Context ctx, Exception e) @trusted { h(ctx, e); }
private void callUser(ValidationErrorHandler h, Context ctx, ValidationErrors errors) @trusted { h(ctx, errors); }

/// A validation error handler set on an App or a Group, with what OpenAPI says about it.
private final class ValidationHook
{
    ValidationErrorHandler handler;
    ValidationDoc doc;

    this(ValidationErrorHandler handler, ValidationDoc doc)
    {
        this.handler = handler;
        this.doc = doc;
    }

    /// `Context.onValidation` for the routes it covers. The response starts as an empty 422, like `onError`'s starts as
    /// an empty 500, so a handler that only writes a body still answers 422.
    void respond(Context ctx)
    {
        ctx.response.status = 422;
        ctx.response.contentType = null;
        ctx.response.body.clear();
        callUser(handler, ctx, ctx.errors.view);
    }
}

/// `onValidationError` for `App` and `Group` (the difference is only where the hook is stored).
private mixin template ValidationSetters()
{
    /// Answers requests whose parameters fail to bind (wrong or missing query, header, cookie, path or body fields)
    /// instead of the default 422. The handler gets the errors and writes the response:
    ///
    ///     app.onValidationError((Context ctx, ValidationErrors errors) {
    ///         if (errors.has(ErrorSource.path))
    ///             return ctx.json(Message("not found"), 404);
    ///         ctx.json(Message(errors.items[0].dotted ~ ": " ~ errors.items[0].message), 400);
    ///     });
    ///
    /// OpenAPI then documents a generic "4XX" error without a body schema; use the `!Body(status, h)` form to declare it.
    /// A group's handler replaces the app's (and a parent group's) for its routes.
    void onValidationError(F)(F h)
    {
        static if (validationHandlerError!F.length)
            static assert(0, validationHandlerError!F);
        else
            setValidation(new ValidationHook(toValidationHandler(h), ValidationDoc(true, 0, null, null)));
    }

    /// Same, and the OpenAPI document says these errors are `status` with a `Body` JSON body:
    /// `app.onValidationError!ApiError(400, (Context ctx, ValidationErrors errors) { ... });`
    void onValidationError(Body, F)(int status, F h, string description = "Validation error")
    {
        static if (!is(Body == struct))
            static assert(0, "vela: onValidationError!(" ~ Body.stringof ~ "): the error body type must be a struct "
                ~ "(it documents the JSON the handler writes)");
        else static if (validationHandlerError!F.length)
            static assert(0, validationHandlerError!F);
        else
        {
            if (status < 100 || status > 599)
                throw new RouteError("vela: onValidationError: " ~ itoa(status) ~ " is not an HTTP status");
            setValidation(new ValidationHook(toValidationHandler(h), ValidationDoc(true, status, description,
                delegate string(ref Components cs) @safe { return schemaOf!Body(cs); })));
        }
    }
}

/// One line saying what is wrong with a validation handler of type `F`, or "".
private enum string validationHandlerError(F) = is(F : ValidationErrorHandler)
    || is(F : void function(Context, ValidationErrors) @system) ? ""
    : "vela: onValidationError takes a function (Context ctx, ValidationErrors errors) returning void, not '"
        ~ F.stringof ~ "'";

/// A user's handler (delegate or function) as a `ValidationErrorHandler`.
private ValidationErrorHandler toValidationHandler(F)(F h)
{
    static if (is(F : ValidationErrorHandler))
        return h;
    else
        return delegate(Context c, ValidationErrors e) @system { h(c, e); };
}

/// Runs a group's middlewares and, at the end, the route's handler.
private final class Chain
{
    Middleware[] mws;
    HandlerFn handler;

    void run(Context ctx, size_t i)
    {
        if (i < mws.length)
            callMiddleware(mws[i], ctx, Next(&run, i + 1, ctx));
        else
            handler(ctx);
    }

    void entry(Context ctx)
    {
        run(ctx, 0);
    }
}

/// Set of routes with their own prefix and middlewares:
///
///     auto api = app.group("/api/v1");
///     api.use(&requireLogin);
///     api.get!("/users/{id}", getUser);        // GET /api/v1/users/{id}, with requireLogin
///
/// A middleware applies to EVERY route of the group and of its subgroups, whenever the route is registered
/// (before or after the `use`). Order: the order of the `use` calls, outermost first; a parent group's middleware
/// runs before its subgroups'. Group middleware runs after routing, so it only sees requests that matched a route.
/// The prefix is plain text: no `{param}` (binding by name is decided at compile time).
final class Group
{
    private App app;
    private string prefix;
    private Group parent;
    private Middleware[] mws;
    private ValidationHook validation;

    private this(App app, string prefix, Group parent)
    {
        this.app = app;
        this.prefix = prefix;
        this.parent = parent;
    }

    mixin ValidationSetters;

    private void setValidation(ValidationHook hook)
    {
        app.mustBeOpen();
        validation = hook;
    }

    /// The nearest validation hook: this group's, a parent's, or null.
    private ValidationHook findValidation()
    {
        for (auto g = this; g !is null; g = g.parent)
            if (g.validation !is null)
                return g.validation;
        return null;
    }

    void use(Middleware mw)
    {
        app.mustBeOpen();
        mws ~= mw;
    }

    void use(void function(Context, Next) @system mw)
    {
        use((Context c, Next n) @trusted => mw(c, n));
    }

    /// Subgroup: its prefix extends this one's, and this group's middleware runs before its own.
    Group group(string sub)
    {
        app.mustBeOpen();
        return new Group(app, prefix ~ checkPrefix(sub), this);
    }

    void register(Method method, string path, HandlerFn h, OpDescribe describe = null)
    {
        auto full = (path == "/" && prefix.length) ? prefix : prefix ~ path;
        app.registerIn(this, method, full, h, describe);
    }

    private void collect(ref Middleware[] outer) // root first
    {
        if (parent !is null)
            parent.collect(outer);
        outer ~= mws;
    }
}

private string checkPrefix(string prefix) pure
{
    if (prefix.length && prefix[0] != '/')
        throw new RouteError("vela: group prefix '" ~ prefix ~ "' must start with '/'");
    if (prefix.length && prefix[$ - 1] == '/')
        throw new RouteError("vela: group prefix '" ~ prefix ~ "' must not end with '/'");
    foreach (char c; prefix)
        if (c == '{' || c == '}')
            throw new RouteError("vela: group prefix '" ~ prefix ~ "' cannot contain {parameters}; "
                ~ "put the parameters in the group's routes");
    return prefix;
}

final class App
{
    private Router router;
    private HandlerFn[] handlers;
    private Group[] owners;          // owners[i] = group of handlers[i], or null
    private Middleware[] middlewares;
    private ErrorHandler errorHandler;
    private UserHandler notFoundHandler;
    private ValidationHook validation;
    private void delegate(Context) @safe[] validationFor; // per handler, built by freeze; null: the default 422
    private OpRecord[] ops;

    private bool frozen;
    private ProxyTrust proxyTrust;
    private bool openApiWanted;
    private OpenApiInfo openApiInfo;
    private string openApiJson;

    /// If the route does not exist but exists with/without the trailing slash, answers 308 to it.
    bool redirectTrailingSlash;

    /// Log the stack trace of unexpected exceptions (not `HttpError`), at most `maxTracesPerSecond` per second.
    bool logStackTraces = true;
    enum int maxTracesPerSecond = 5;
    private long traceWindowMs = long.min / 2;
    private int tracesInWindow;

    this()
    {
        router = new Router;
    }

    // ---- middlewares (registration order = outside in)

    /// App-level middleware: runs for every request, before routing (so it also sees 404 and 405), in the order of the
    /// `use` calls, outermost first. Whenever it is registered, it applies to all routes.
    void use(Middleware mw)
    {
        mustBeOpen();
        middlewares ~= mw;
    }

    void use(void function(Context, Next) @system mw)
    {
        use((Context c, Next n) @trusted => mw(c, n));
    }

    /// Creates a route group with its own prefix and middlewares.
    Group group(string prefix)
    {
        mustBeOpen();
        return new Group(this, checkPrefix(prefix), null);
    }

    /// Everything (routes, middleware, handlers) must be set up before the first request: `freeze` builds the
    /// per-route middleware chains and the OpenAPI document, and nothing changes afterwards, so workers can read the
    /// app without locks. `serve` freezes each worker's app; `handle` freezes it on the first request (TestClient).
    private void mustBeOpen() const
    {
        if (frozen)
            throw new RouteError("vela: the app is already serving; register routes and middleware before serve "
                ~ "(in the build function)");
    }

    /// Believes `X-Forwarded-For` (or `header`) from these proxies, given as CIDR strings: `ctx.clientIp()` and `ClientIp`
    /// then return the real client. `serve` does this from `ServerConfig.trustedProxies`. Throws `RouteError` on a bad CIDR.
    void trustProxies(const(string)[] cidrs, string header = "X-Forwarded-For")
    {
        mustBeOpen();
        Cidr[] nets;
        foreach (c; cidrs)
        {
            Cidr n;
            if (!parseCidr(c, n))
                throw new RouteError("vela: trusted proxy '" ~ c ~ "' is not an address or a CIDR (10.0.0.0/8, 127.0.0.1, ::1/128)");
            nets ~= n;
        }
        proxyTrust = ProxyTrust(nets, header);
    }

    /// Handles any exception thrown by handlers and middlewares (including `HttpError`).
    /// Exceptions that are not `HttpError` are still logged first.
    void onError(ErrorHandler h)
    {
        mustBeOpen();
        errorHandler = h;
    }

    mixin ValidationSetters;

    private void setValidation(ValidationHook hook)
    {
        mustBeOpen();
        validation = hook;
    }

    /// Response for nonexistent routes (replaces the default JSON 404).
    void onNotFound(UserHandler h)
    {
        mustBeOpen();
        notFoundHandler = h;
    }

    /// Registers an already-generated handler. The `get`/`post`/... functions below
    /// validate the signature at compile time and call this.
    void register(Method method, string path, HandlerFn h, OpDescribe describe = null)
    {
        registerIn(null, method, path, h, describe);
    }

    private void registerIn(Group owner, Method method, string path, HandlerFn h, OpDescribe describe)
    {
        mustBeOpen();
        handlers ~= h;
        owners ~= owner;
        router.add(method, path, cast(int)(handlers.length - 1));
        ops ~= OpRecord(method, path, describe);
    }

    /// Wraps each grouped route in its group chain and builds the OpenAPI document. Idempotent.
    void freeze()
    {
        if (frozen)
            return;
        validationFor = new void delegate(Context) @safe[handlers.length];
        foreach (i, g; owners)
        {
            auto hook = g is null ? null : g.findValidation();
            if (hook is null)
                hook = validation;
            if (hook !is null)
            {
                validationFor[i] = &hook.respond;
                ops[i].validation = hook.doc;
            }
            if (g is null)
                continue;
            Middleware[] all;
            g.collect(all);
            if (all.length == 0)
                continue;
            auto c = new Chain;
            c.mws = all;
            c.handler = handlers[i];
            handlers[i] = &c.entry;
        }
        if (openApiWanted)
            openApiJson = buildOpenApi(ops, openApiInfo);
        frozen = true;
    }

    /// Publishes `/openapi.json` (and the `/docs` page) generated from the signatures of ALL the handlers of the
    /// app, including those registered after this call (the document is built when the app starts serving).
    void serveOpenApi(OpenApiInfo info = OpenApiInfo.init)
    {
        mustBeOpen();
        openApiWanted = true;
        openApiInfo = info;
        if (info.jsonPath.length)
            register(Method.GET, info.jsonPath, delegate(Context c) {
                c.response.contentType = "application/json";
                c.response.body.put(openApiJson);
            });
        if (info.docsPath.length)
        {
            auto html = docsHtml(info.jsonPath, info.title, info.swaggerUiBase);
            register(Method.GET, info.docsPath, delegate(Context c) {
                c.response.contentType = "text/html; charset=utf-8";
                c.response.body.put(html);
            });
        }
    }

    /// Registers every method of `controller` annotated with @Get/@Post/...
    /// Use it for handlers with state (repositories, connections, config).
    void mount(C, string file = __FILE__, size_t line = __LINE__)(C controller) if (is(C == class))
    {
        static foreach (member; __traits(allMembers, C))
        {
            static if (__traits(compiles, __traits(getOverloads, C, member)))
            {
                static foreach (ov; __traits(getOverloads, C, member))
                {
                    static foreach (attr; __traits(getAttributes, ov))
                    {
                        static if (is(typeof(attr) == Route))
                        {{
                            enum err = handlerError!(attr.method, attr.path, ov, file, line, attr.websocket);
                            static if (err.length)
                                static assert(0, err);
                            else static if (attr.websocket) // not in OpenAPI, which cannot describe WebSockets
                                register(attr.method, attr.path, delegate(Context c) { dispatch!(attr.method, attr.path, ov)(c, controller); });
                            else
                                register(attr.method, attr.path, delegate(Context c) { dispatch!(attr.method, attr.path, ov)(c, controller); },
                                    delegate string(ref Components cs, string pat) @safe { return describeOperation!(attr.method, attr.path, ov)(cs, pat); });
                        }}
                    }
                }
            }
        }
    }

    /// Route tree as text (debugging).
    string routes() const => router.dump();

    // ---- execution

    /// Processes the request already loaded in `ctx`. Never throws.
    void handle(Context ctx)
    {
        if (!frozen)
            freeze();
        ctx.proxies = &proxyTrust;
        try
            runFrom(ctx, 0);
        catch (Exception e)
            fail(ctx, e);
        finishResponse(ctx);
    }

    /// The one validation point, after the middleware has unwound (see `checkResponse`). A streamed response whose
    /// head was already committed is left alone: its status and headers are on the wire.
    private static void finishResponse(Context ctx)
    {
        if (ctx.committed)
            return;
        if (!checkResponse(ctx))
        {
            ctx.response.clearHeaders();
            renderError(ctx, 500, "internal error");
            ctx.response.ensureHeader("Date", httpDate());
        }
    }

    private void fail(Context ctx, Exception e)
    {
        if (ctx.committed)
        {
            // A streamed response already started: status and headers are on the wire, so no error page is possible.
            // The failure is logged and the response is cut off (HTTP/1.1: connection closed without the final chunk;
            // HTTP/2: stream reset), which is the only honest signal left to the client.
            logError(ctx, e);
            ctx.aborted = true;
            return;
        }
        if (errorHandler is null)
        {
            if (auto he = cast(HttpError) e)
                renderError(ctx, he.status, he.msg);
            else
                internalError(ctx, e);
            return;
        }
        if (cast(HttpError) e is null)
            logError(ctx, e);
        ctx.response.status = 500;
        ctx.response.contentType = null;
        ctx.response.body.clear();
        try
            callUser(errorHandler, ctx, e);
        catch (Exception e2) // the error handler failed too: nothing more to do
        {
            logError(ctx, e2);
            renderError(ctx, 500, "internal error");
        }
    }

    private void runFrom(Context ctx, size_t i)
    {
        if (i < middlewares.length)
            callMiddleware(middlewares[i], ctx, Next(&runFrom, i + 1, ctx));
        else
            endpoint(ctx);
    }

    private void endpoint(Context ctx)
    {
        auto r = router.match(ctx.request.method, ctx.request.path, ctx.params);
        final switch (r.status)
        {
            case MatchStatus.found:
                ctx.onValidation = validationFor[r.handler];
                try
                    handlers[r.handler](ctx);
                catch (Exception e) // caught here so the middlewares see the final status
                    fail(ctx, e);
                break;
            case MatchStatus.notFound:
                // (not for an HTTP/2 WebSocket: a client does not follow a redirect of its extended CONNECT)
                if (redirectTrailingSlash && ctx.request.connectProtocol.length == 0 && tryTrailingSlash(ctx))
                    break;
                if (notFoundHandler !is null)
                {
                    try
                        callUser(notFoundHandler, ctx);
                    catch (Exception e)
                        fail(ctx, e);
                }
                else
                    renderError(ctx, 404, "not found");
                break;
            case MatchStatus.methodNotAllowed:
                ctx.setHeader("Allow", allowList(ctx, r.allowed));
                renderError(ctx, 405, "method not allowed");
                break;
        }
    }

    /// "/a/b/" <-> "/a/b": if the other form exists, redirect (308 keeps method and body).
    private bool tryTrailingSlash(Context ctx)
    {
        auto p = ctx.request.path;
        if (p.length == 0)
            return false;
        PathParams scratch;
        immutable stripped = p.length > 1 && p[$ - 1] == '/';
        auto alt = stripped ? p[0 .. $ - 1] : p;
        // to "add", build in the context's scratch (no GC in the common case)
        char[] buf;
        if (!stripped)
        {
            buf = ctx.scratch(p.length + 1 + (ctx.request.query.length ? ctx.request.query.length + 1 : 0));
            buf[0 .. p.length] = p;
            buf[p.length] = '/';
            alt = buf[0 .. p.length + 1];
        }
        if (router.match(ctx.request.method, alt, scratch).status != MatchStatus.found)
            return false;

        char[] loc;
        if (stripped)
            loc = ctx.scratch(alt.length + (ctx.request.query.length ? ctx.request.query.length + 1 : 0));
        else
            loc = buf; // already has the room for the query
        size_t n = alt.length;
        if (stripped)
            loc[0 .. n] = alt;
        if (ctx.request.query.length)
        {
            loc[n++] = '?';
            loc[n .. n + ctx.request.query.length] = ctx.request.query;
            n += ctx.request.query.length;
        }
        ctx.response.status = 308;
        ctx.response.contentType = null;
        ctx.response.body.clear();
        ctx.setHeader("Location", loc[0 .. n]);
        return true;
    }

    private static const(char)[] allowList(Context ctx, ushort mask) nothrow @nogc @safe
    {
        size_t n = 0;
        foreach (i; 0 .. methodCount)
        {
            if (!(mask & (1 << i)))
                continue;
            auto name = methodName(cast(Method) i);
            if (n)
            {
                ctx.allowBuf[n .. n + 2] = ", ";
                n += 2;
            }
            ctx.allowBuf[n .. n + name.length] = name;
            n += name.length;
        }
        return ctx.allowBuf[0 .. n];
    }

    private static void renderError(Context ctx, int status, scope const(char)[] msg)
    {
        ctx.response.status = status;
        ctx.response.contentType = "application/json";
        ctx.response.body.clear();
        ctx.response.body.put(`{"detail":`);
        writeJsonString(ctx.response.body, msg);
        ctx.response.body.put('}');
    }

    private void internalError(Context ctx, Exception e)
    {
        logError(ctx, e);
        renderError(ctx, 500, "internal error");
    }

    /// Logs the exception behind a 500 (details only in the log, never in the response). With `logStackTraces` the
    /// whole `toString()` goes out -- message, file:line and stack trace (needs debug info: build with `-g`, or DUB's
    /// `release-debug` type, for symbol names) -- at most `maxTracesPerSecond` times per second per App; the rest get
    /// the one-line form. Each worker has its own App, so the limit is per worker.
    private void logError(Context ctx, Exception e) nothrow @trusted
    {
        import core.stdc.stdio : fprintf, stderr;
        import core.time : MonoTime;

        // @trusted: fprintf with explicit lengths on strings that stay alive during the call
        immutable m = methodName(ctx.request.method);
        if (logStackTraces)
        {
            immutable now = MonoTime.currTime.ticks / (MonoTime.ticksPerSecond / 1000); // ms
            if (now - traceWindowMs >= 1000)
            {
                traceWindowMs = now;
                tracesInWindow = 0;
            }
            if (tracesInWindow < maxTracesPerSecond)
            {
                tracesInWindow++;
                string text;
                try
                    text = e.toString();
                catch (Exception)
                    text = e.msg;
                fprintf(stderr, "vela: error in %.*s %.*s: %.*s\n", cast(int) m.length, m.ptr,
                    cast(int) ctx.request.path.length, ctx.request.path.ptr, cast(int) text.length, text.ptr);
                return;
            }
        }
        fprintf(stderr, "vela: error in %.*s %.*s: %.*s (%.*s:%d)\n", cast(int) m.length, m.ptr,
            cast(int) ctx.request.path.length, ctx.request.path.ptr,
            cast(int) e.msg.length, e.msg.ptr, cast(int) e.file.length, e.file.ptr, cast(int) e.line);
    }
}

// ---- route registration: free functions called via UFCS (`app.get!(...)`).
// Free, and not App methods, on purpose: that way a local lambda that
// captures dependencies (`(long id) => repo.find(id)`) becomes an ordinary closure,
// without the "dual-context" that D deprecated. Validation runs here, at the
// user's call site, and the compile error is only two lines.
// They work for `App` and for `Group` (`api.get!("/x", fn)`).

private enum isRouteTarget(R) = is(R == App) || is(R == Group);

void get(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.GET, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.GET, path, delegate(Context c) { dispatch!(Method.GET, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.GET, path, fn)(cs, pat); });
}

void post(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.POST, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.POST, path, delegate(Context c) { dispatch!(Method.POST, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.POST, path, fn)(cs, pat); });
}

void put(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.PUT, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.PUT, path, delegate(Context c) { dispatch!(Method.PUT, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.PUT, path, fn)(cs, pat); });
}

void patch(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.PATCH, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.PATCH, path, delegate(Context c) { dispatch!(Method.PATCH, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.PATCH, path, fn)(cs, pat); });
}

void del(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.DELETE, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.DELETE, path, delegate(Context c) { dispatch!(Method.DELETE, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.DELETE, path, fn)(cs, pat); });
}

/// A WebSocket route: a GET whose handler returns `WebSocket` (see vela.web.websocket). Not in the OpenAPI document,
/// which cannot describe WebSockets.
void ws(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.GET, path, fn, file, line, true);
    static if (err.length) static assert(0, err);
    else app.register(Method.GET, path, delegate(Context c) { dispatch!(Method.GET, path, fn)(c); });
}
