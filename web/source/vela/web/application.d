/// `App`: route registration, middlewares and the per-request entry point.
module vela.web.application;

@safe:

import vela.http.types;
import vela.web.context;
import vela.web.params : HttpError;
import vela.web.router;
import vela.web.handler_traits : handlerError, dispatch;
import vela.web.json : writeJsonString;
import vela.web.openapi;

/// Route UDA for controller methods: `@Get("/users/{id}")`.
struct Route
{
    Method method;
    string path;
}

Route Get(string path) => Route(Method.GET, path);
Route Post(string path) => Route(Method.POST, path);
Route Put(string path) => Route(Method.PUT, path);
Route Patch(string path) => Route(Method.PATCH, path);
Route Delete(string path) => Route(Method.DELETE, path);

alias HandlerFn = void delegate(Context);

/// Called instead of the default handling when a handler or middleware throws.
/// Write the response into `ctx` (`ctx.text(...)`, `ctx.response.status = ...`).
alias ErrorHandler = void delegate(Context ctx, Exception e);

/// Runs a group's middlewares and, at the end, the route's handler.
private final class Chain
{
    Middleware[] mws;
    HandlerFn handler;

    void run(Context ctx, size_t i)
    {
        if (i < mws.length)
            mws[i](ctx, Next(&run, i + 1, ctx));
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
/// A middleware applies to routes registered AFTER the `use` (as in Express).
/// The prefix is plain text: no `{param}` (binding by name is decided at compile time).
final class Group
{
    private App app;
    private string prefix;
    private Middleware[] mws;

    private this(App app, string prefix, Middleware[] inherited)
    {
        this.app = app;
        this.prefix = prefix;
        this.mws = inherited;
    }

    void use(Middleware mw)
    {
        mws ~= mw;
    }

    void use(void function(Context, Next) @safe mw)
    {
        mws ~= (Context c, Next n) => mw(c, n);
    }

    /// Subgroup: inherits the current prefix and middlewares.
    Group group(string sub)
    {
        return new Group(app, prefix ~ checkPrefix(sub), mws.dup);
    }

    void register(Method method, string path, HandlerFn h, OpDescribe describe = null)
    {
        auto full = (path == "/" && prefix.length) ? prefix : prefix ~ path;
        if (mws.length == 0)
            return app.register(method, full, h, describe);
        auto c = new Chain;
        c.mws = mws.dup;
        c.handler = h;
        app.register(method, full, &c.entry, describe);
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
    private Middleware[] middlewares;
    private ErrorHandler errorHandler;
    private HandlerFn notFoundHandler;
    private OpRecord[] ops;

    /// If the route does not exist but exists with/without the trailing slash, answers 308 to it.
    bool redirectTrailingSlash;

    this()
    {
        router = new Router;
    }

    // ---- middlewares (registration order = outside in)

    void use(Middleware mw)
    {
        middlewares ~= mw;
    }

    void use(void function(Context, Next) @safe mw)
    {
        middlewares ~= (Context c, Next n) => mw(c, n);
    }

    /// Creates a route group with its own prefix and middlewares.
    Group group(string prefix)
    {
        return new Group(this, checkPrefix(prefix), null);
    }

    /// Handles any exception thrown by handlers and middlewares (including `HttpError`).
    /// Exceptions that are not `HttpError` are still logged first.
    void onError(ErrorHandler h)
    {
        errorHandler = h;
    }

    /// Response for nonexistent routes (replaces the default JSON 404).
    void onNotFound(HandlerFn h)
    {
        notFoundHandler = h;
    }

    /// Registers an already-generated handler. The `get`/`post`/... functions below
    /// validate the signature at compile time and call this.
    void register(Method method, string path, HandlerFn h, OpDescribe describe = null)
    {
        handlers ~= h;
        router.add(method, path, cast(int)(handlers.length - 1));
        ops ~= OpRecord(method, path, describe);
    }

    /// Publishes `/openapi.json` (and the `/docs` page) generated from the signatures of the
    /// handlers registered UP TO here. Call it after registering the routes.
    void serveOpenApi(OpenApiInfo info = OpenApiInfo.init)
    {
        auto records = ops.dup;
        string cached;
        if (info.jsonPath.length)
            register(Method.GET, info.jsonPath, delegate(Context c) {
                if (cached is null)
                    cached = buildOpenApi(records, info);
                c.response.contentType = "application/json";
                c.response.body.put(cached);
            });
        if (info.docsPath.length)
        {
            auto html = docsHtml(info.jsonPath, info.title);
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
                            enum err = handlerError!(attr.method, attr.path, ov, file, line);
                            static if (err.length)
                                static assert(0, err);
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
        try
            runFrom(ctx, 0);
        catch (Exception e)
            fail(ctx, e);
    }

    private void fail(Context ctx, Exception e)
    {
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
            errorHandler(ctx, e);
        catch (Exception e2) // the error handler failed too: nothing more to do
        {
            logError(ctx, e2);
            renderError(ctx, 500, "internal error");
        }
    }

    private void runFrom(Context ctx, size_t i)
    {
        if (i < middlewares.length)
            middlewares[i](ctx, Next(&runFrom, i + 1, ctx));
        else
            endpoint(ctx);
    }

    private void endpoint(Context ctx)
    {
        auto r = router.match(ctx.request.method, ctx.request.path, ctx.params);
        final switch (r.status)
        {
            case MatchStatus.found:
                try
                    handlers[r.handler](ctx);
                catch (Exception e) // caught here so the middlewares see the final status
                    fail(ctx, e);
                break;
            case MatchStatus.notFound:
                if (redirectTrailingSlash && tryTrailingSlash(ctx))
                    break;
                if (notFoundHandler !is null)
                {
                    try
                        notFoundHandler(ctx);
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

    private static void internalError(Context ctx, Exception e)
    {
        logError(ctx, e);
        renderError(ctx, 500, "internal error");
    }

    private static void logError(Context ctx, Exception e) nothrow @trusted
    {
        import core.stdc.stdio : fprintf, stderr;

        // details only in the log, never in the response
        fprintf(stderr, "vela: error in %.*s %.*s: %.*s (%.*s:%d)\n",
            cast(int) methodName(ctx.request.method).length, methodName(ctx.request.method).ptr,
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
