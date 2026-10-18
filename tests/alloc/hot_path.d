/// Guarantees the framework's hot path does not allocate on the GC:
/// routing + path/query extraction + middleware + response JSON.
import andaime;
import andaime.http : splitTarget;
import core.memory : GC;
import core.stdc.stdio : printf;

struct Out { long id; long doubled; bool even; }

Out calc(long id, int factor = 2) @safe => Out(id, id * factor, id % 2 == 0);

void passThrough(Context ctx, Next next) @safe
{
    ctx.setHeader("X-Engine", "andaime");
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

    foreach (i; 0 .. 100) // warm-up: buffers grow once
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
    printf("bytes allocated on the GC in 100k requests: %llu\n", cast(ulong)(after - before));
    assert(after == before, "the hot path allocated on the GC");
}
