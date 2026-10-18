/// Glue between `andaime:web` (App) and `andaime:engine` (transport).
/// It is the only module that knows both layers.
module andaime.server;

@safe:

import andaime.http;
import andaime.web.application : App;
import andaime.web.stream : sendResponse;
import andaime.web.context : Context;
import andaime.engine.loop : ServerConfig, HandlerFactory, RequestCallback, WorkerInit;
import andaime.engine.fiberio : workerIndex, currentFiberLocal, setCurrentFiberLocal;
import andaime.log : LogScope, setLogFiberSource;

/// andaime.log's context inside an engine fiber: the id of the Context the running request fiber carries, or the LogScope
/// of a job (`--role=all` runs jobs on worker 0). True when running in such a fiber (even without an id), so the logger
/// never falls back to another request's.
private bool fiberRequestId(out const(char)[] id, out LogScope fields) nothrow
{
    auto local = currentFiberLocal();
    if (auto ctx = cast(Context) local)
    {
        id = ctx.logRequestId();
        return true;
    }
    if (auto s = cast(LogScope) local)
    {
        fields = s;
        return true;
    }
    return false;
}
import core.stdc.stdlib : exit;
import core.sync.mutex : Mutex;
import andaime.engine.devserver : runDevServer;
import andaime.engine.epoll : runEpollServer;
import andaime.engine.zlib : zlibDeflate;

/// Starts the server. Each worker (one per core by default) calls `build` once, on its own thread, and serves the App it
/// returns, so everything `build` creates -- the App, controllers, module-level state, `pgPool`, `httpClient` -- belongs to
/// one worker and needs no locking:
///
///     App buildApp()
///     {
///         auto app = new App;
///         app.get!("/users/{id}", getUser);
///         return app;
///     }
///
///     void main() { serve(&buildApp, 8080); }
///
/// `build` must create a new App on every call and register all routes and middleware inside; it may run on several
/// threads at once. The app is frozen when the worker starts serving. To share data between workers use a database, or
/// `__gshared`/`shared` data behind a lock (see docs/concurrency.md, "Workers and state").
void serve(App delegate() @system build, ushort port = 8080)
{
    ServerConfig cfg;
    cfg.port = port;
    serve(build, cfg);
}

/// ditto
void serve(App function() @system build, ushort port = 8080)
{
    ServerConfig cfg;
    cfg.port = port;
    serve(build, cfg);
}

/// ditto
void serve(App function() @system build, ServerConfig cfg, void delegate() @safe onWorker0 = null)
{
    serve(() @trusted => build(), cfg, onWorker0); // sound: `build` is user code like any other delegate we call via callBuild
}

/// ditto
void serve(App delegate() @system build, ServerConfig cfg, void delegate() @safe onWorker0 = null)
{
    if (!tryServe(build, cfg, onWorker0))
        (() @trusted => exit(1))(); // sound: ends the process; the engine already said why on stderr
}

/// ditto. A function (a lambda with no captures) is not a delegate; `null` still selects the delegate overload.
void serve(F)(App function() @system build, ServerConfig cfg, F onWorker0)
if (is(F == void function() @safe))
{
    serve(() @trusted => build(), cfg, onWorker0); // sound: `build` is user code like any other delegate we call via callBuild
}

/// ditto
void serve(F)(App delegate() @system build, ServerConfig cfg, F onWorker0)
if (is(F == void function() @safe))
{
    if (onWorker0 is null)
        serve(build, cfg);
    else
    {
        auto call = onWorker0;
        serve(build, cfg, () { call(); });
    }
}

/// Like `serve`, but returns false instead of exiting when the server could not start (the build function threw or
/// returned an App twice, the port is taken, the TLS files are bad). Returns true after a graceful stop. For tests and
/// for programs that want to handle the failure themselves.
///
/// `onWorker0`, when non-null, runs at the end of worker 0's init (the App is already built and frozen), on that
/// worker's thread. That is the place to `spawn` background fibers. `null` keeps the previous behavior.
///
/// With the environment variable `ANDAIME_ROUTES` set (to anything but "" or "0"), the build function runs once on the
/// calling thread, `App.routeTable` goes to stdout and this returns true at once: no port, no worker (`andaime routes`).
bool tryServe(App delegate() @system build, ServerConfig cfg, void delegate() @safe onWorker0 = null)
{
    if (routesRequested())
    {
        auto app = callBuild(build);
        if (app is null)
            throw new Exception("andaime: the build function returned null; it must return the App to serve");
        writeStdout(app.routeTable());
        return true;
    }
    // a bad proxy entry fails startup with one line, before any worker builds anything
    foreach (c; cfg.trustedProxies)
    {
        Cidr probe;
        if (!parseCidr(c, probe))
        {
            (() @trusted {
                import core.stdc.stdio : fprintf, stderr;
                fprintf(stderr, "andaime: ServerConfig.trustedProxies: '%.*s' is not an address or a CIDR (10.0.0.0/8, 127.0.0.1, ::1/128)\n",
                    cast(int) c.length, c.ptr);
            })();
            return false;
        }
    }
    auto seen = new SeenApps;
    WorkerInit init = () {
        setLogFiberSource(&fiberRequestId); // this worker's thread: andaime.log asks the running fiber for its request
        auto app = callBuild(build);
        if (app is null)
            throw new Exception("andaime: the build function returned null; it must return the App to serve");
        seen.add(app);
        if (cfg.trustedProxies.length)
            app.trustProxies(cfg.trustedProxies, cfg.forwardedHeader);
        app.freeze();
        if (onWorker0 !is null && workerIndex == 0)
            onWorker0();
        return handlerFactory(app);
    };
    // @trusted: the engine is raw-syscall @system code, but it only ever calls back into `@safe` handlers
    // (RequestCallback is a @safe delegate) and owns its fds and buffers.
    return (() @trusted => runEpollServer(cfg, init))();
}

/// ditto
bool tryServe(App function() @system build, ServerConfig cfg, void delegate() @safe onWorker0 = null)
{
    return tryServe(() @trusted => build(), cfg, onWorker0); // sound: same as the `serve` overload
}

/// ditto. A function (a lambda with no captures) is not a delegate; `null` still selects the delegate overload.
bool tryServe(F)(App delegate() @system build, ServerConfig cfg, F onWorker0)
if (is(F == void function() @safe))
{
    if (onWorker0 is null)
        return tryServe(build, cfg);
    auto call = onWorker0;
    return tryServe(build, cfg, () { call(); });
}

/// ditto
bool tryServe(F)(App function() @system build, ServerConfig cfg, F onWorker0)
if (is(F == void function() @safe))
{
    if (onWorker0 is null)
        return tryServe(build, cfg);
    auto call = onWorker0;
    return tryServe(() @trusted => build(), cfg, () { call(); }); // sound: same as the `serve` overload
}

/// `ANDAIME_ROUTES` is set to something other than "" or "0".
private bool routesRequested() @trusted nothrow @nogc
{
    import core.stdc.stdlib : getenv;

    // sound: getenv returns a NUL-terminated string owned by the environment; only its first two bytes are read here
    auto p = getenv("ANDAIME_ROUTES");
    return p !is null && p[0] != '\0' && !(p[0] == '0' && p[1] == '\0');
}

/// Writes `text` to stdout and flushes it.
private void writeStdout(string text) @trusted nothrow @nogc
{
    import core.stdc.stdio : fflush, fwrite, stdout;

    // sound: fwrite reads exactly text.length bytes from text.ptr
    fwrite(text.ptr, 1, text.length, stdout);
    fflush(stdout);
}

/// The single place where the user's build function is called from `@safe` framework code.
/// @trusted: the callee's own safety is the user's business; nothing here touches its memory.
private App callBuild(App delegate() @system build) @trusted
{
    return build();
}

/// Remembers the Apps the build function returned, to catch `serve(() => sharedApp)`: one App for all workers is exactly
/// the data race this API exists to prevent. Startup only; the build functions of different workers run concurrently.
private final class SeenApps
{
    private Mutex mutex;
    private App[] apps;

    this()
    {
        mutex = new Mutex;
    }

    void add(App app)
    {
        synchronized (mutex)
        {
            foreach (a; apps)
                if (a is app)
                    throw new Exception("andaime: the build function must create a new App for each worker "
                        ~ "(it returned the same object twice); move `new App` and the route registration inside it");
            apps ~= app;
        }
    }
}

/// Creates, for each engine fiber, its own Context and the callback that uses it.
/// One Context per fiber (not per request): requests suspended at the same
/// time cannot share the same one.
HandlerFactory handlerFactory(App app)
{
    return () {
        auto ctx = new Context;
        ctx.newDeflate = (int bits, bool noContext) => zlibDeflate(bits, noContext); // WebSocket compression
        RequestCallback cb = (ref Request req, ResponseSink sink) {
            ctx.reset(req, sink);
            setCurrentFiberLocal(ctx); // the request fiber carries its Context (andaime.log reads the request id)
            scope (exit)
            {
                ctx.response.body.shrinkTo(64 << 10); // a response peak does not stay pinned to the Context
                ctx.request = Request.init;           // nor does a request body: an idle fiber must not pin its buffer
                ctx.sink = null;
            }
            app.handle(ctx);
            sendResponse(ctx);
        };
        return cb;
    };
}
