/// Web-layer features a real application uses: groups with middleware,
/// ctx.locals / Local!T, onError, onNotFound, trailing slash and CORS.
module features;

@safe:

import vela;
import vela.web.testing;

struct User { int id; string name; }

string hi() => "hi";
string me(Local!User u) => u.name;
string boom() { throw new Exception("internal secret"); }
string denied() { throw new HttpError(403, "forbidden"); }
string orphan(Local!User u) => u.name;
string echo(string x) => x;
string id(int n) => "id=" ~ (n < 10 ? "0" : "") ~ "x";

App build(ref string[] trace)
{
    auto app = new App;
    app.redirectTrailingSlash = true;
    app.use(cors(CorsConfig(["https://app.example.com"], "GET, POST", null, "X-Total", true)));
    app.use((Context c, Next n) { trace ~= "app>"; n(); trace ~= "<app"; });

    app.get!("/hi", hi);
    app.get!("/boom", boom);
    app.get!("/denied", denied);
    app.get!("/orphan", orphan);

    auto api = app.group("/api");
    api.use((Context c, Next n) { trace ~= "api>"; n(); trace ~= "<api"; });
    api.get!("/hi", hi);
    api.get!("/", hi);

    auto admin = api.group("/admin");
    admin.use((Context c, Next n) {
        auto tok = c.request.header("Authorization");
        if (tok != "Bearer ok")
            throw new HttpError(401, "missing token");
        c.locals.set(User(1, "ana"));
        trace ~= "admin>";
        n();
    });
    admin.get!("/me", me);
    admin.get!("/x/{x}", echo);
    return app;
}

unittest
{
    string[] trace;
    auto c = TestClient(build(trace));

    // group: prefix + middleware only on the group's routes
    auto r = c.get("/hi");
    assert(r.status == 200 && r.body == "hi");
    assert(trace == ["app>", "<app"], "group middleware leaked outside");
    trace = null;
    r = c.get("/api/hi");
    assert(r.status == 200 && r.body == "hi");
    assert(trace == ["app>", "api>", "<api", "<app"], trace[0]);
    assert(c.get("/api").body == "hi", "the group's '/' becomes the prefix itself");

    // subgroup inherits middlewares and uses locals
    assert(c.get("/api/admin/me").status == 401);
    trace = null;
    r = c.get("/api/admin/me", hdr("Authorization", "Bearer ok"));
    assert(r.status == 200 && r.body == "ana");
    assert(trace == ["app>", "api>", "admin>", "<api", "<app"]);
    assert(c.get("/api/admin/x/abc", hdr("Authorization", "Bearer ok")).body == "abc");

    // Local!T without middleware: configuration error, 500 without leaking details
    r = c.get("/orphan");
    assert(r.status == 500 && r.body == `{"detail":"internal error"}`);

    // locals do not leak between requests
    c.get("/api/admin/me", hdr("Authorization", "Bearer ok"));
    assert(c.get("/orphan").status == 500);

    // trailing slash
    r = c.get("/hi/?a=1");
    assert(r.status == 308 && r.header("Location") == "/hi?a=1", r.header("Location"));
    r = c.get("/api/");
    assert(r.status == 308 && r.header("Location") == "/api");
    assert(c.get("/nada/").status == 404); // neither with nor without slash: ordinary 404
    assert(c.get("/api/hi/").status == 308);
}

unittest
{
    string[] trace;
    auto c = TestClient(build(trace));
    string ori = "https://app.example.com";

    // without Origin: no CORS headers
    auto r = c.get("/hi");
    assert(r.header("Access-Control-Allow-Origin") is null);
    assert(r.headers("Vary") == ["Origin"], "a cache must not reuse the no-CORS variant for an allowed origin");

    // allowed origin
    r = c.get("/hi", hdr("Origin", ori));
    assert(r.status == 200);
    assert(r.header("Access-Control-Allow-Origin") == ori && r.header("Vary") == "Origin");
    assert(r.header("Access-Control-Allow-Credentials") == "true");
    assert(r.header("Access-Control-Expose-Headers") == "X-Total");

    // unknown origin: no headers (the browser blocks it)
    r = c.get("/hi", hdr("Origin", "https://mal.com"));
    assert(r.status == 200 && r.header("Access-Control-Allow-Origin") is null);
    assert(r.headers("Vary") == ["Origin"]);

    // preflight of a route that only exists for GET: 204 without going through the router
    r = c.send(Method.OPTIONS, "/hi", null, [hdr("Origin", ori), hdr("Access-Control-Request-Method", "POST"),
        hdr("Access-Control-Request-Headers", "content-type,authorization")]);
    assert(r.status == 204, "preflight");
    assert(r.header("Access-Control-Allow-Methods") == "GET, POST");
    assert(r.header("Access-Control-Allow-Headers") == "content-type,authorization");
    assert(r.header("Access-Control-Max-Age") == "600");
    assert(r.body.length == 0);
    assert(r.headers("Vary") == ["Origin, Access-Control-Request-Method, Access-Control-Request-Headers"], r.header("Vary"));

    // a preflight that asks for no particular headers does not vary on them
    r = c.send(Method.OPTIONS, "/hi", null, [hdr("Origin", ori), hdr("Access-Control-Request-Method", "POST")]);
    assert(r.status == 204 && r.headers("Vary") == ["Origin, Access-Control-Request-Method"], r.header("Vary"));
}

unittest
{
    // `*` without credentials: the answer never depends on the origin, so only a preflight varies
    auto app = new App;
    app.use(cors(CorsConfig(["*"])));
    app.get!("/hi", hi);
    auto c = TestClient(app);
    auto r = c.get("/hi", hdr("Origin", "https://any.example"));
    assert(r.header("Access-Control-Allow-Origin") == "*" && r.header("Vary") is null);
    r = c.get("/hi");
    assert(r.header("Vary") is null);
    r = c.send(Method.OPTIONS, "/hi", null, [hdr("Origin", "https://any.example"), hdr("Access-Control-Request-Method", "GET")]);
    assert(r.status == 204 && r.headers("Vary") == ["Access-Control-Request-Method"], r.header("Vary"));

    // `*` with credentials echoes the origin, so it varies on it
    auto app2 = new App;
    app2.use(cors(CorsConfig(["*"], "GET", null, null, true)));
    app2.get!("/hi", hi);
    auto c2 = TestClient(app2);
    r = c2.get("/hi", hdr("Origin", "https://x.example"));
    assert(r.header("Access-Control-Allow-Origin") == "https://x.example" && r.headers("Vary") == ["Origin"]);
}

unittest
{
    string[] trace;
    auto app = build(trace);
    app.onError((Context ctx, Exception e) {
        if (auto he = cast(HttpError) e)
            ctx.text("http:" ~ he.msg, he.status);
        else
            ctx.text("failure", 500);
    });
    app.onNotFound((Context ctx) { ctx.text("gone", 404); });
    auto c = TestClient(app);

    auto r = c.get("/boom");
    assert(r.status == 500 && r.body == "failure", "internal details must not leak");
    r = c.get("/denied");
    assert(r.status == 403 && r.body == "http:forbidden");
    r = c.get("/does-not-exist");
    assert(r.status == 404 && r.body == "gone");
    // an exception thrown by a middleware also goes through onError
    r = c.get("/api/admin/me");
    assert(r.status == 401 && r.body == "http:missing token");
}

unittest
{
    // an invalid prefix is a startup error with a clear message
    auto app = new App;
    foreach (bad; ["api", "/api/", "/o/{id}"])
    {
        bool threw;
        try app.group(bad);
        catch (Exception e) threw = true;
        assert(threw, bad);
    }
}

unittest
{
    // requestId + accessLog + bearerToken
    string seen;
    auto app = new App;
    app.use(requestId());
    app.use(accessLog());
    app.get!("/rid", (Local!RequestId r) => cast(string) r.value.idup);
    app.get!("/tok", (Context c) => bearerToken(c).idup);
    auto c = TestClient(app);

    auto r = c.get("/rid");
    assert(r.body.length == 16 && r.header("X-Request-Id") == r.body);
    auto r2 = c.get("/rid");
    assert(r2.body != r.body, "ids should vary");
    r = c.get("/rid", hdr("X-Request-Id", "abc-123"));
    assert(r.body == "abc-123" && r.header("X-Request-Id") == "abc-123");
    r = c.get("/rid", hdr("X-Request-Id", "evil\r\nSet-Cookie: x"));
    assert(r.body.length == 16, "an unsafe id must be discarded");

    assert(c.get("/tok", hdr("Authorization", "Bearer abc.def")).body == "abc.def");
    assert(c.get("/tok").body == "");
    assert(c.get("/tok", hdr("Authorization", "Basic xyz")).body == "");
}
