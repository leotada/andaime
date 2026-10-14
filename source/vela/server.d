/// Glue between `vela:web` (App) and `vela:engine` (transport).
/// It is the only module that knows both layers.
module vela.server;

@safe:

import vela.http;
import vela.web.application : App;
import vela.web.stream : sendResponse;
import vela.web.context : Context;
import vela.engine.loop : ServerConfig, HandlerFactory, RequestCallback, WorkerInit;
import core.stdc.stdlib : exit;
import core.sync.mutex : Mutex;
import vela.engine.devserver : runDevServer;
version (linux)
    import vela.engine.epoll : runEpollServer;

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
void serve(App function() @system build, ServerConfig cfg)
{
    serve(() @trusted => build(), cfg); // sound: `build` is user code like any other delegate we call via callBuild
}

/// ditto
void serve(App delegate() @system build, ServerConfig cfg)
{
    if (!tryServe(build, cfg))
        (() @trusted => exit(1))(); // sound: ends the process; the engine already said why on stderr
}

/// Like `serve`, but returns false instead of exiting when the server could not start (the build function threw or
/// returned an App twice, the port is taken, the TLS files are bad). Returns true after a graceful stop. For tests and
/// for programs that want to handle the failure themselves.
bool tryServe(App delegate() @system build, ServerConfig cfg)
{
    // a bad proxy entry fails startup with one line, before any worker builds anything
    foreach (c; cfg.trustedProxies)
    {
        Cidr probe;
        if (!parseCidr(c, probe))
        {
            (() @trusted {
                import core.stdc.stdio : fprintf, stderr;
                fprintf(stderr, "vela: ServerConfig.trustedProxies: '%.*s' is not an address or a CIDR (10.0.0.0/8, 127.0.0.1, ::1/128)\n",
                    cast(int) c.length, c.ptr);
            })();
            return false;
        }
    }
    auto seen = new SeenApps;
    WorkerInit init = () {
        auto app = callBuild(build);
        if (app is null)
            throw new Exception("vela: the build function returned null; it must return the App to serve");
        seen.add(app);
        if (cfg.trustedProxies.length)
            app.trustProxies(cfg.trustedProxies, cfg.forwardedHeader);
        app.freeze();
        return handlerFactory(app);
    };
    // @trusted: the engine is raw-syscall @system code, but it only ever calls back into `@safe` handlers
    // (RequestCallback is a @safe delegate) and owns its fds and buffers.
    version (linux)
        return (() @trusted => runEpollServer(cfg, init))();
    else
    {
        () @trusted { runDevServer(cfg, init()()); }();
        return true;
    }
}

/// ditto
bool tryServe(App function() @system build, ServerConfig cfg)
{
    return tryServe(() @trusted => build(), cfg); // sound: same as the `serve` overload
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
                    throw new Exception("vela: the build function must create a new App for each worker "
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
        RequestCallback cb = (ref Request req, ResponseSink sink) {
            ctx.reset(req, sink);
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
