/// Server for the throughput benchmark (tools/bench.sh): a few routes that exercise the usual hot path.
///   GET /plaintext          a string
///   GET /json               a struct serialized to JSON
///   GET /users/{id}?full=1  a path parameter, a query parameter and a header, behind an app middleware
/// Usage: bench_serve [port=18100] [workers=1]
module bench_serve;

import vela;

@safe:

struct Message { string message; }

struct User { long id; string name; bool full; string agent; }

string plaintext() => "Hello, World!";

Message json() => Message("Hello, World!");

User user(long id, Header!"User-Agent" agent, bool full = false) => User(id, "user", full, agent.value);

void serverHeader(Context ctx, Next next)
{
    ctx.setHeader("Server", "vela");
    next();
}

@system:

void main(string[] args)
{
    import std.conv : to;

    ServerConfig cfg;
    cfg.port = args.length > 1 ? args[1].to!ushort : 18100;
    cfg.workers = args.length > 2 ? args[2].to!uint : 1;
    serve(() {
        auto app = new App;
        app.use(&serverHeader);
        app.get!("/plaintext", plaintext);
        app.get!("/json", json);
        app.get!("/users/{id}", user);
        return app;
    }, cfg);
}
