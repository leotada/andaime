/// Glue between `vela:web` (App) and `vela:engine` (transport).
/// It is the only module that knows both layers.
module vela.server;

@safe:

import vela.http;
import vela.web.application : App;
import vela.web.context : Context;
import vela.engine.loop : ServerConfig, HandlerFactory, RequestCallback;
import vela.engine.devserver : runDevServer;
version (linux)
    import vela.engine.epoll : runEpollServer;

/// Starts the server. Usage: `app.serve(8080);`
void serve(App app, ushort port = 8080)
{
    ServerConfig cfg;
    cfg.port = port;
    serve(app, cfg);
}

void serve(App app, ServerConfig cfg)
{
    // @trusted: the engine is raw-syscall @system code, but it only ever calls back into
    // `@safe` handlers (RequestCallback is a @safe delegate) and owns its fds and buffers.
    version (linux)
        () @trusted { runEpollServer(cfg, handlerFactory(app)); }();
    else
        () @trusted { runDevServer(cfg, handlerFactory(app)()); }();
}

/// Creates, for each engine fiber, its own Context and the callback that uses it.
/// One Context per fiber (not per request): requests suspended at the same
/// time cannot share the same one.
HandlerFactory handlerFactory(App app)
{
    return () {
        auto ctx = new Context;
        RequestCallback cb = (ref Request req, ref ByteBuffer o) {
            ctx.reset(req);
            app.handle(ctx);
            ctx.response.setHeader("Date", httpDate());
            auto body = ctx.response.body.data;
            writeResponseHead(o, ctx.response.status, ctx.response.contentType, body.length,
                ctx.response.headers, req.keepAlive);
            if (req.method != Method.HEAD && ctx.response.status != 204 && ctx.response.status != 304)
                o.put(body);
            ctx.response.body.shrinkTo(64 << 10); // a response peak does not stay pinned to the Context
        };
        return cb;
    };
}
