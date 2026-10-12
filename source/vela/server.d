/// Cola entre `vela:web` (App) e `vela:engine` (transporte).
/// É o único módulo que conhece as duas camadas.
module vela.server;

import vela.http;
import vela.web.application : App;
import vela.web.context : Context;
import vela.engine.loop : ServerConfig, HandlerFactory, RequestCallback;
import vela.engine.devserver : runDevServer;
version (linux)
    import vela.engine.epoll : runEpollServer;

/// Sobe o servidor. Uso: `app.serve(8080);`
void serve(App app, ushort port = 8080)
{
    ServerConfig cfg;
    cfg.port = port;
    serve(app, cfg);
}

void serve(App app, ServerConfig cfg)
{
    version (linux)
        runEpollServer(cfg, handlerFactory(app));
    else
        runDevServer(cfg, handlerFactory(app)());
}

/// Cria, para cada fiber do engine, um Context próprio e o callback que o usa.
/// Um Context por fiber (não por requisição): requisições suspensas ao mesmo
/// tempo não podem dividir o mesmo.
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
            ctx.response.body.shrinkTo(64 << 10); // pico de resposta não fica preso ao Context
        };
        return cb;
    };
}
