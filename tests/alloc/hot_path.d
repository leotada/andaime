/// Garante que o caminho quente do framework não aloca no GC:
/// roteamento + extração de path/query + middleware + JSON de resposta.
import vela;
import vela.http : splitTarget;
import core.memory : GC;
import core.stdc.stdio : printf;

struct Out { long id; long doubled; bool even; }

Out calc(long id, int factor = 2) => Out(id, id * factor, id % 2 == 0);

void passThrough(Context ctx, Next next)
{
    ctx.setHeader("X-Engine", "vela");
    next();
}

void main()
{
    auto app = new App;
    app.use(&passThrough);
    app.get!("/calc/{id}", calc);

    auto ctx = new Context;
    Request req;
    req.method = Method.GET;
    req.target = "/calc/21?factor=3";
    splitTarget(req.target, req.path, req.query);

    foreach (i; 0 .. 100) // aquecimento: buffers crescem uma vez
    {
        ctx.reset(req);
        app.handle(ctx);
    }
    immutable before = GC.allocatedInCurrentThread;
    foreach (i; 0 .. 100_000)
    {
        ctx.reset(req);
        app.handle(ctx);
    }
    immutable after = GC.allocatedInCurrentThread;

    assert(ctx.response.body.data == `{"id":21,"doubled":63,"even":false}`);
    printf("bytes alocados no GC em 100k requisições: %llu\n", cast(ulong)(after - before));
    assert(after == before, "o caminho quente alocou no GC");
}
