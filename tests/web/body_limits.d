/// Per-route body limits: `App.bodyLimit`, `Group.bodyLimit` and `@bodyLimit`, for buffered and streamed bodies.
module body_limits_test 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.conv : to;

struct Note
{
    string text;
}

/// What the app middleware saw last: the status after the chain, and whether the body was still unread.
string seen;

void watch(Context ctx, Next next)
{
    next();
    seen = ctx.response.status.to!string ~ "/" ~ (ctx.request.bodyReader !is null ? "unread" : "read");
}

void requireToken(Context ctx, Next next)
{
    if (ctx.request.header("X-Token") != "ok")
        throw new HttpError(401, "no token");
    next();
}

string note(JsonBody!Note n) => n.text.length.to!string;

@bodyLimit(700_000) string upload(Context ctx) => ctx.request.body.length.to!string;

@bodyLimit(300_000) string stream(BodyStream body)
{
    ubyte[4096] buf;
    ulong total;
    size_t n;
    while ((n = body.read(buf[])) > 0)
        total += n;
    return total.to!string;
}

final class Files
{
    @Post("/inside") string inside(Context ctx) => ctx.request.body.length.to!string;
    @bodyLimit(2_000) @Post("/raised") string raised(Context ctx) => ctx.request.body.length.to!string;
}

App build()
{
    auto app = new App;
    app.use(&watch);
    app.bodyLimit(1_000);
    app.post!("/note", note);
    app.post!("/upload", upload);
    app.post!("/stream", stream);
    auto files = app.group("/files");
    files.use(&requireToken);
    files.bodyLimit(500);
    files.mount(new Files);
    auto open = files.group("/open");
    open.post!("/any", (Context c) => c.request.body.length.to!string);
    return app;
}

private string text(size_t n)
{
    auto b = new char[n];
    b[] = 'x';
    return (() @trusted => cast(string) b)();
}

private string json(size_t n) => `{"text":"` ~ text(n) ~ `"}`;

private auto jsonType() => hdr("Content-Type", "application/json");

private auto token() => hdr("X-Token", "ok");

enum tooLarge = `{"detail":"request body too large"}`;

@system unittest
{
    auto c = TestClient(build());

    // the app's limit: within it the route works, above it a 413 that the app middleware still sees
    assert(c.post("/note", json(900), jsonType).body == "900");
    auto r = c.post("/note", json(1_000), jsonType);
    assert(r.status == 413 && r.body == tooLarge, r.body);
    assert(seen == "413/read", seen);

    // a route's @bodyLimit raises it; a body above bufferBodyBytes over the limit is refused without being read
    assert(c.post("/upload", text(600_000)).body == "600000");
    r = c.post("/upload", text(800_000));
    assert(r.status == 413 && r.body == tooLarge, r.body);
    assert(seen == "413/unread", seen);

    // a streaming route: within the limit it reads everything; above it 413 before the handler, nothing read
    assert(c.post("/stream", text(290_000)).body == "290000");
    r = c.post("/stream", text(310_000));
    assert(r.status == 413 && seen == "413/unread", r.body);

    // a group's limit, below the app's; a method's @bodyLimit wins over it; a subgroup inherits it
    assert(c.post("/files/inside", text(500), token).body == "500");
    assert(c.post("/files/inside", text(501), token).status == 413);
    assert(c.post("/files/raised", text(1_500), token).body == "1500");
    assert(c.post("/files/raised", text(2_001), token).status == 413);
    assert(c.post("/files/open/any", text(501), token).status == 413);

    // the group middleware answers first: no token is a 401 even with a body over the limit
    r = c.post("/files/inside", text(501));
    assert(r.status == 401, r.body);

    // no limit on a route that does not exist: still a 404
    assert(c.post("/nowhere", text(5_000)).status == 404);

    // a GET has no body to limit
    assert(c.get("/files/inside", token).status == 405);
}

@system unittest
{
    import std.exception : assertThrown;

    auto app = new App;
    assertThrown!RouteError(app.bodyLimit(0));
    assertThrown!RouteError(app.group("/g").bodyLimit(0));
}
