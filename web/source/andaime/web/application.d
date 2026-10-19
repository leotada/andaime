/// `App`: route registration, middlewares and the per-request entry point.
module andaime.web.application 2025;

@safe:

import andaime.http.types;
import andaime.http.ip : Cidr, parseCidr;
import andaime.web.context;
import andaime.web.params : HttpError;
import andaime.web.dto : ValidationErrors;
import andaime.web.numtext : itoa, ctNum;
import andaime.log : LogLevel, logEnabled, logAndaime, setLogSyncSource;
import andaime.web.router;
import andaime.web.handler_traits : handlerError, dispatch;
import andaime.web.json : writeJsonString, writeJson;
import andaime.web.errors : ErrorInfo, errorBodyError, mapBodyError, validationMessage;
import andaime.web.openapi;
import andaime.web.response_check : checkResponse;
import andaime.http.date : httpDate;

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

/// Writes the body of an error into `ctx` (see `App.errorBody`). The framework builds it around the user's function.
alias ErrorBodyHandler = void delegate(Context ctx, ref const ErrorInfo e) @system;

// @trusted: single entry points for user callbacks (their safety is the user's business)
private void callUser(ErrorBodyHandler h, Context ctx, ref const ErrorInfo e) @trusted { h(ctx, e); }
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
            static assert(0, "andaime: onValidationError!(" ~ Body.stringof ~ "): the error body type must be a struct "
                ~ "(it documents the JSON the handler writes)");
        else static if (validationHandlerError!F.length)
            static assert(0, validationHandlerError!F);
        else
        {
            if (status < 100 || status > 599)
                throw new RouteError("andaime: onValidationError: " ~ itoa(status) ~ " is not an HTTP status");
            setValidation(new ValidationHook(toValidationHandler(h), ValidationDoc(true, status, description,
                delegate string(ref Components cs) @safe { return schemaOf!Body(cs); })));
        }
    }
}

/// One line saying what is wrong with a validation handler of type `F`, or "".
private enum string validationHandlerError(F) = is(F : ValidationErrorHandler)
    || is(F : void function(Context, ValidationErrors) @system) ? ""
    : "andaime: onValidationError takes a function (Context ctx, ValidationErrors errors) returning void, not '"
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
    private bool slashSet;
    private TrailingSlash slash;

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

    /// The trailing-slash policy of this group's routes (and its subgroups', unless they set their own): `strict` or
    /// `matchBoth`. Unset, the group follows `App.trailingSlash`. `redirect` is app-wide only (it throws here).
    void trailingSlash(TrailingSlash policy)
    {
        app.mustBeOpen();
        if (policy == TrailingSlash.redirect)
            throw new RouteError("andaime: a group's trailingSlash is strict or matchBoth; redirect is app-wide "
                ~ "(App.trailingSlash)");
        slash = policy;
        slashSet = true;
    }

    /// The nearest policy: this group's, a parent's, or the app's.
    private TrailingSlash slashPolicy()
    {
        for (auto g = this; g !is null; g = g.parent)
            if (g.slashSet)
                return g.slash;
        return app.trailingSlash;
    }

    /// Subgroup: its prefix extends this one's, and this group's middleware runs before its own.
    Group group(string sub)
    {
        app.mustBeOpen();
        return new Group(app, prefix ~ checkPrefix(sub), this);
    }

    /// `name` is what `App.routeTable` shows for the route (`get!` and `mount` pass the handler's qualified name).
    void register(Method method, string path, HandlerFn h, OpDescribe describe = null, string name = null)
    {
        auto full = (path == "/" && prefix.length) ? prefix : prefix ~ path;
        app.registerIn(this, method, full, h, describe, name);
    }

    /// Registers every method of `controller` annotated with @Get/@Post/..., like `App.mount`. The paths are relative to
    /// the group's prefix and the group's middleware applies.
    void mount(C, string file = __FILE__, size_t line = __LINE__)(C controller) if (is(C == class))
    {
        mixin(mountBody);
    }

    private void collect(ref Middleware[] outer) // root first
    {
        if (parent !is null)
            parent.collect(outer);
        outer ~= mws;
    }
}

/// What a request whose path differs from a route only by a trailing slash (`/tasks/` for `/tasks`, or the reverse) gets.
enum TrailingSlash
{
    strict,    /// a 404: the slash is part of the path
    redirect,  /// a 308 to the route's form (app-wide only: it is decided before routing)
    matchBoth, /// the route itself, with no redirect; OpenAPI shows the registered form
}

/// The route pattern with its trailing slash added or removed, or "" when it has no other form (`/`, or a `{*rest}`
/// pattern, which already takes any tail).
private string otherSlashForm(string pattern) pure nothrow
{
    if (pattern.length <= 1)
        return null;
    if (pattern[$ - 1] == '/')
        return pattern[0 .. $ - 1];
    size_t s = pattern.length;
    while (s > 0 && pattern[s - 1] != '/')
        s--;
    if (pattern.length - s >= 2 && pattern[s] == '{' && pattern[s + 1] == '*')
        return null;
    return pattern ~ "/";
}

unittest
{
    assert(otherSlashForm("/") is null);
    assert(otherSlashForm("/api/tasks") == "/api/tasks/");
    assert(otherSlashForm("/api/tasks/") == "/api/tasks");
    assert(otherSlashForm("/users/{id}") == "/users/{id}/");
    assert(otherSlashForm("/files/{*path}") is null);
}

private string checkPrefix(string prefix) pure
{
    if (prefix.length && prefix[0] != '/')
        throw new RouteError("andaime: group prefix '" ~ prefix ~ "' must start with '/'");
    if (prefix.length && prefix[$ - 1] == '/')
        throw new RouteError("andaime: group prefix '" ~ prefix ~ "' must not end with '/'");
    foreach (char c; prefix)
        if (c == '{' || c == '}')
            throw new RouteError("andaime: group prefix '" ~ prefix ~ "' cannot contain {parameters}; "
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
    private UserHandler methodNotAllowedHandler;
    private ValidationHook validation;
    private void delegate(Context) @safe[] validationFor; // per handler, built by freeze; null: the default 422
    private OpRecord[] ops;
    private ErrorMapping[] errorMappings;                  // see `mapError`
    private ErrorBody errorBodyOf;                         // see `errorBody`; `render` null: the default bodies

    private bool frozen;
    private ProxyTrust proxyTrust;
    private bool openApiWanted;
    private OpenApiInfo openApiInfo;
    private string openApiJson;

    /// If the route does not exist but exists with/without the trailing slash, answers 308 to it. Same as
    /// `trailingSlash = TrailingSlash.redirect`.
    bool redirectTrailingSlash;

    /// What a path that differs from a route only by a trailing slash gets (see `TrailingSlash`). A `Group` may
    /// choose `strict` or `matchBoth` for its own routes.
    TrailingSlash trailingSlash = TrailingSlash.strict;

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
            throw new RouteError("andaime: the app is already serving; register routes and middleware before serve "
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
                throw new RouteError("andaime: trusted proxy '" ~ c ~ "' is not an address or a CIDR (10.0.0.0/8, 127.0.0.1, ::1/128)");
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

    /// Treats an exception of type `E` (or a subclass) as `HttpError(status, e.msg)`: it answers `status` with
    /// `{"detail": msg}` (or the `errorBody`), it is not logged, and an `onError` handler receives that `HttpError`,
    /// whose `cause` is the original exception. For your own exceptions that are answers, not failures: a domain's
    /// `NotFound`, `Conflict`... (`app.mapError!NotFound(404)`). The first mapping that matches wins. Throws `RouteError`
    /// for a status outside 400-599.
    void mapError(E : Exception)(int status)
    {
        addMapping!E(status, ErrorMapping((Exception e) => cast(E) e !is null, status));
    }

    /// Same, with this mapping's own body: `app.mapError!Conflict(409, (Conflict e) => ApiError(e.msg, e.code))`. It wins
    /// over `errorBody` for this exception (same content type).
    void mapError(E : Exception, F)(int status, F render)
    {
        static if (mapBodyError!(E, F).length)
            static assert(0, mapBodyError!(E, F));
        else
        {
            ErrorBodyHandler h = delegate(Context ctx, ref const ErrorInfo info) @system {
                // the exception as thrown (ErrorInfo only lends it as const)
                auto b = render(cast(E) cast(Exception) info.exception);
                writeJson(ctx.response.body, b);
            };
            addMapping!E(status, ErrorMapping((Exception e) => cast(E) e !is null, status, h));
        }
    }

    private void addMapping(E)(int status, ErrorMapping m)
    {
        mustBeOpen();
        if (status < 400 || status > 599)
            throw new RouteError("andaime: mapError!" ~ E.stringof ~ ": " ~ itoa(status)
                ~ " is not an error status (400-599)");
        errorMappings ~= m;
    }

    /// One body format for every error the app answers by itself: a mapped exception (`mapError`), an `HttpError`, a
    /// validation error (422), a route that does not exist (404) or does not take the method (405), and an unexpected
    /// exception (500, logged as before). `render` turns an `ErrorInfo` into a struct, sent as JSON with `contentType`:
    ///
    ///     struct ApiError { string message; string code; }
    ///     app.errorBody((ref const ErrorInfo e) {
    ///         auto d = cast(const DomainError) e.exception;    // the exception as thrown, or null
    ///         return ApiError(e.message, d is null ? "error" : d.code);
    ///     });
    ///
    /// The specific hooks keep priority: a mapping's own body, `onError`, `onValidationError`, `onNotFound` and
    /// `onMethodNotAllowed` answer their errors themselves. OpenAPI documents the errors it lists with `render`'s body.
    /// `app.errorBody(&problemDetails, problemJson)` gives RFC 9457 problem details.
    void errorBody(F)(F render, string contentType = "application/json")
    {
        static if (errorBodyError!F.length)
            static assert(0, errorBodyError!F);
        else
        {
            mustBeOpen();
            static if (is(F R == return))
                alias Body = R;
            errorBodyOf = ErrorBody(delegate(Context ctx, ref const ErrorInfo info) @system {
                auto b = render(info);
                writeJson(ctx.response.body, b);
            }, contentType, delegate string(ref Components cs) @safe { return schemaOf!Body(cs); });
        }
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

    /// Response for a path that exists for other methods (replaces the default JSON 405). The `Allow` header is already
    /// set when `h` runs, and the status is 405 until `h` sets one (`ctx.json(err, 405)`).
    void onMethodNotAllowed(UserHandler h)
    {
        mustBeOpen();
        methodNotAllowedHandler = h;
    }

    /// Registers an already-generated handler. The `get`/`post`/... functions below
    /// validate the signature at compile time and call this. `name` is what `routeTable` shows for the route.
    void register(Method method, string path, HandlerFn h, OpDescribe describe = null, string name = null)
    {
        registerIn(null, method, path, h, describe, name);
    }

    private void registerIn(Group owner, Method method, string path, HandlerFn h, OpDescribe describe, string name)
    {
        mustBeOpen();
        handlers ~= h;
        owners ~= owner;
        router.add(method, path, cast(int)(handlers.length - 1));
        OpRecord op;
        op.method = method;
        op.pattern = path;
        op.describe = describe;
        op.handler = name;
        ops ~= op;
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
            else if (errorBodyOf.render !is null)
            {
                validationFor[i] = &renderValidation;
                ops[i].validation = ValidationDoc(true, 422, "Validation error", errorBodyOf.schema,
                    errorBodyOf.contentType);
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
        // `matchBoth`: the other form of each route goes to the same handler. Added after every explicit route, so an
        // explicit route with that form keeps it (the router refuses the duplicate). Not an OpenAPI operation.
        immutable registered = ops.length;
        foreach (i; 0 .. registered)
        {
            auto g = owners[i];
            if ((g is null ? trailingSlash : g.slashPolicy()) != TrailingSlash.matchBoth)
                continue;
            immutable alt = otherSlashForm(ops[i].pattern);
            if (alt.length == 0)
                continue;
            try
                router.add(ops[i].method, alt, cast(int) i);
            catch (RouteError)
            {
            }
        }
        if (openApiWanted)
            openApiJson = buildOpenApi(ops, openApiInfo, errorBodyOf.schema, errorBodyOf.contentType);
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
            }, null, "(andaime: OpenAPI)");
        if (info.docsPath.length)
        {
            auto html = docsHtml(info.jsonPath, info.title, info.swaggerUiBase);
            register(Method.GET, info.docsPath, delegate(Context c) {
                c.response.contentType = "text/html; charset=utf-8";
                c.response.body.put(html);
            }, null, "(andaime: Swagger UI)");
        }
    }

    /// Registers every method of `controller` annotated with @Get/@Post/...
    /// Use it for handlers with state (repositories, connections, config). `Group.mount` does the same under a prefix.
    void mount(C, string file = __FILE__, size_t line = __LINE__)(C controller) if (is(C == class))
    {
        mixin(mountBody);
    }

    /// Route tree as text (debugging).
    string routes() const => router.dump();

    /// The routes as aligned text, one line each in registration order: method, path and handler (its fully qualified
    /// name, `file:line` for a lambda, or a label for andaime's own routes). `ANDAIME_ROUTES=1` makes `serve` print it.
    string routeTable() const
    {
        size_t width;
        foreach (ref op; ops)
            if (op.pattern.length > width)
                width = op.pattern.length;
        string o;
        foreach (ref op; ops)
        {
            o ~= padRight(methodName(op.method), 8);
            o ~= padRight(op.pattern, width + 2);
            o ~= op.handler.length ? op.handler : "-";
            o ~= '\n';
        }
        return o;
    }

    // ---- execution

    /// Processes the request already loaded in `ctx`. Never throws.
    void handle(Context ctx)
    {
        if (!frozen)
            freeze();
        ctx.proxies = &proxyTrust;
        // without fibers (TestClient, the development server) andaime.log finds this request's id here
        auto prevLogSource = setLogSyncSource(&ctx.logRequestId);
        scope (exit)
            setLogSyncSource(prevLogSource);
        try
            runFrom(ctx, 0);
        catch (Exception e)
            fail(ctx, e);
        finishResponse(ctx);
    }

    /// The one validation point, after the middleware has unwound (see `checkResponse`). A streamed response whose
    /// head was already committed is left alone: its status and headers are on the wire.
    private void finishResponse(Context ctx)
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
        const(ErrorMapping)* mapped;
        foreach (ref m; errorMappings)
            if (m.matches(e))
            {
                mapped = &m;
                break;
            }
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
            if (mapped !is null)
                renderError(ctx, ErrorInfo(mapped.status, e.msg, e), mapped.render);
            else if (auto he = cast(HttpError) e)
                renderError(ctx, ErrorInfo(he.status, he.msg, he.cause !is null ? he.cause : he));
            else
            {
                logError(ctx, e);
                renderError(ctx, ErrorInfo(500, "internal error", e));
            }
            return;
        }
        if (mapped !is null)
        {
            auto he = new HttpError(mapped.status, e.msg, e.file, e.line);
            he.cause = e;
            e = he;
        }
        else if (cast(HttpError) e is null)
            logError(ctx, e);
        ctx.response.status = 500;
        ctx.response.contentType = null;
        ctx.response.body.clear();
        try
            callUser(errorHandler, ctx, e);
        catch (Exception e2) // the error handler failed too: nothing more to do
        {
            logError(ctx, e2);
            renderDefault(ctx, 500, "internal error");
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
                if ((redirectTrailingSlash || trailingSlash == TrailingSlash.redirect)
                    && ctx.request.connectProtocol.length == 0 && tryTrailingSlash(ctx))
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
                if (methodNotAllowedHandler !is null)
                {
                    ctx.response.status = 405;
                    try
                        callUser(methodNotAllowedHandler, ctx);
                    catch (Exception e)
                        fail(ctx, e);
                }
                else
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

    /// An error answered by andaime itself (404, 405, the 500 of a response that failed its checks).
    private void renderError(Context ctx, int status, string msg)
    {
        renderError(ctx, ErrorInfo(status, msg));
    }

    /// The body of an error: `own` (a mapping's), else `errorBody`'s, else the default `{"detail": msg}`.
    private void renderError(Context ctx, ErrorInfo info, ErrorBodyHandler own = null)
    {
        auto render = own !is null ? own : errorBodyOf.render;
        if (render is null)
            return renderDefault(ctx, info.status, info.message);
        ctx.response.status = info.status;
        ctx.response.contentType = errorBodyOf.contentType.length ? errorBodyOf.contentType : "application/json";
        ctx.response.body.clear();
        try
            callUser(render, ctx, info);
        catch (Exception e) // the renderer failed: the plain body, never a half-written one
        {
            logError(ctx, e);
            renderDefault(ctx, 500, "internal error");
        }
    }

    private static void renderDefault(Context ctx, int status, scope const(char)[] msg)
    {
        ctx.response.status = status;
        ctx.response.contentType = "application/json";
        ctx.response.body.clear();
        ctx.response.body.put(`{"detail":`);
        writeJsonString(ctx.response.body, msg);
        ctx.response.body.put('}');
    }

    /// `Context.onValidation` when `errorBody` is set and no `onValidationError` covers the route.
    private void renderValidation(Context ctx)
    {
        auto v = ctx.errors.view;
        renderError(ctx, ErrorInfo(422, validationMessage(v), null, v));
    }

    /// Logs the exception behind a 500 (details only in the log, never in the response). With `logStackTraces` the
    /// whole `toString()` goes out -- message, file:line and stack trace (needs debug info: build with `-g`, or DUB's
    /// `release-debug` type, for symbol names) -- at most `maxTracesPerSecond` times per second per App; the rest get
    /// the one-line form. Each worker has its own App, so the limit is per worker. It goes through `andaime.log` at the
    /// `error` level: the same line in the `text` format, `msg="error in handler"` with `method`, `path` and `error` in
    /// `kv`/`json` (the trace kept in one line).
    private void logError(Context ctx, Exception e) nothrow
    {
        import core.time : MonoTime;

        if (!logEnabled(LogLevel.error))
            return;
        immutable m = methodName(ctx.request.method);
        string text;
        bool full;
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
                full = true;
                try
                    text = (() @trusted => e.toString())(); // sound: formats the message, file:line and trace into a new string
                catch (Exception)
                    text = e.msg;
            }
        }
        if (!full)
            text = e.msg ~ " (" ~ e.file ~ ":" ~ itoa(e.line) ~ ")";
        auto legacy = "andaime: error in " ~ m ~ " " ~ ctx.request.path ~ ": " ~ text;
        logAndaime(LogLevel.error, legacy, "error in handler", "method", m, "path", ctx.request.path, "error", text);
    }
}

/// An exception type answered as an `HttpError` (see `App.mapError`).
private struct ErrorMapping
{
    bool function(Exception) @safe matches;
    int status;
    ErrorBodyHandler render; /// the mapping's own body, or null
}

/// What `App.errorBody` set.
private struct ErrorBody
{
    ErrorBodyHandler render;
    string contentType;
    string delegate(ref Components) @safe schema; /// for OpenAPI
}

/// `s` followed by spaces up to `width` characters (the columns of `App.routeTable`).
private string padRight(string s, size_t width) pure nothrow
{
    string o = s;
    foreach (_; s.length .. width)
        o ~= ' ';
    return o;
}

/// What `App.routeTable` shows for a handler: its fully qualified name, or where a lambda was written (a lambda's own
/// name is a compiler artifact).
private template handlerName(alias fn, string file, size_t line)
{
    private enum id = __traits(identifier, fn);
    static if (id.length >= 8 && id[0 .. 8] == "__lambda")
        enum handlerName = file ~ ":" ~ ctNum(line);
    else
        enum handlerName = __traits(fullyQualifiedName, fn);
}

/// The body of `App.mount` and `Group.mount`: registers every method of `controller` that carries a `Route` UDA. Mixed
/// into each (not a shared function) so that a bad signature stays a two-line compile error.
private enum string mountBody = q{
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
                            register(attr.method, attr.path, delegate(Context c) { dispatch!(attr.method, attr.path, ov)(c, controller); },
                                null, __traits(fullyQualifiedName, ov) ~ " (WebSocket)");
                        else
                            register(attr.method, attr.path, delegate(Context c) { dispatch!(attr.method, attr.path, ov)(c, controller); },
                                delegate string(ref Components cs, string pat) @safe { return describeOperation!(attr.method, attr.path, ov)(cs, pat); },
                                __traits(fullyQualifiedName, ov));
                    }}
                }
            }
        }
    }
};

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
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.GET, path, fn)(cs, pat); },
        handlerName!(fn, file, line));
}

void post(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.POST, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.POST, path, delegate(Context c) { dispatch!(Method.POST, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.POST, path, fn)(cs, pat); },
        handlerName!(fn, file, line));
}

void put(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.PUT, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.PUT, path, delegate(Context c) { dispatch!(Method.PUT, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.PUT, path, fn)(cs, pat); },
        handlerName!(fn, file, line));
}

void patch(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.PATCH, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.PATCH, path, delegate(Context c) { dispatch!(Method.PATCH, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.PATCH, path, fn)(cs, pat); },
        handlerName!(fn, file, line));
}

void del(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.DELETE, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.DELETE, path, delegate(Context c) { dispatch!(Method.DELETE, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.DELETE, path, fn)(cs, pat); },
        handlerName!(fn, file, line));
}

/// A WebSocket route: a GET whose handler returns `WebSocket` (see andaime.web.websocket). Not in the OpenAPI document,
/// which cannot describe WebSockets.
void ws(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.GET, path, fn, file, line, true);
    static if (err.length) static assert(0, err);
    else app.register(Method.GET, path, delegate(Context c) { dispatch!(Method.GET, path, fn)(c); }, null,
        handlerName!(fn, file, line) ~ " (WebSocket)");
}
