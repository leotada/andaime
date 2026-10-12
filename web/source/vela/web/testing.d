/// In-memory client: exercises App + handlers without sockets.
module vela.web.testing;

import vela.http.types;
import vela.web.context;
import vela.web.application;

struct TestResponse
{
    int status;
    string contentType;
    string body;
    HeaderField[] headers;

    string header(string name) const
    {
        foreach (h; headers)
            if (equalsIgnoreCase(h.name, name))
                return cast(string) h.value;
        return null;
    }
}

HeaderField hdr(string name, string value) => HeaderField(name, value);

struct TestClient
{
    private App app;
    private Context ctx;

    this(App app)
    {
        this.app = app;
        ctx = new Context;
    }

    TestResponse get(string target, HeaderField[] headers...) => send(Method.GET, target, null, headers);
    TestResponse post(string target, string body, HeaderField[] headers...) => send(Method.POST, target, body, headers);
    TestResponse put(string target, string body, HeaderField[] headers...) => send(Method.PUT, target, body, headers);
    TestResponse del(string target, HeaderField[] headers...) => send(Method.DELETE, target, null, headers);

    TestResponse send(Method m, string target, string body, HeaderField[] headers)
    {
        Request req;
        req.method = m;
        req.target = target;
        splitTarget(target, req.path, req.query);
        req.headers = headers.dup;
        req.body = cast(const(ubyte)[]) body;
        ctx.reset(req);
        app.handle(ctx);

        TestResponse r;
        r.status = ctx.response.status;
        r.contentType = ctx.response.contentType.idup;
        r.body = ctx.response.body.data.idup;
        foreach (h; ctx.response.headers)
            r.headers ~= HeaderField(h.name.idup, h.value.idup);
        return r;
    }
}
