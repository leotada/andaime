/// Middleware ordering and freezing: a middleware applies to every route of its App/Group whenever it is registered,
/// runs in the order of the `use` calls (outermost first), and nothing can be registered once the app is serving.
module ordering;

@safe:

import andaime;
import andaime.web.testing;

string hi() => "hi";
string late() => "late";

unittest
{
    string[] trace;
    auto app = new App;
    app.get!("/a", hi);
    auto g = app.group("/g");
    g.get!("/before", hi);
    auto sub = g.group("/sub"); // created before the parent's middleware
    sub.get!("/x", hi);
    // all of these come AFTER the routes
    app.use((Context c, Next n) { trace ~= "app1>"; n(); trace ~= "<app1"; });
    app.use((Context c, Next n) { trace ~= "app2>"; n(); trace ~= "<app2"; });
    g.use((Context c, Next n) { trace ~= "g1>"; n(); trace ~= "<g1"; });
    g.use((Context c, Next n) { trace ~= "g2>"; n(); trace ~= "<g2"; });
    sub.use((Context c, Next n) { trace ~= "sub>"; n(); trace ~= "<sub"; });
    g.get!("/after", hi);

    auto c = TestClient(app);
    assert(c.get("/a").body == "hi");
    assert(trace == ["app1>", "app2>", "<app2", "<app1"], "app middleware applies to a route registered before it");

    trace = null;
    assert(c.get("/g/before").status == 200);
    assert(trace == ["app1>", "app2>", "g1>", "g2>", "<g2", "<g1", "<app2", "<app1"], "group middleware applies to a route registered before it");

    trace = null;
    assert(c.get("/g/after").status == 200);
    assert(trace == ["app1>", "app2>", "g1>", "g2>", "<g2", "<g1", "<app2", "<app1"]);

    trace = null;
    assert(c.get("/g/sub/x").status == 200);
    assert(trace == ["app1>", "app2>", "g1>", "g2>", "sub>", "<sub", "<g2", "<g1", "<app2", "<app1"],
        "a subgroup runs its parent's middleware first, even one added after the subgroup was created");

    // group middleware runs after routing: a 404 under the prefix never reaches it
    trace = null;
    assert(c.get("/g/nothing").status == 404);
    assert(trace == ["app1>", "app2>", "<app2", "<app1"]);
}

unittest
{
    // once the app has served a request (or `serve` started), it cannot change
    auto app = new App;
    app.get!("/a", hi);
    auto g = app.group("/g");
    auto c = TestClient(app);
    assert(c.get("/a").status == 200);

    void expectRouteError(scope void delegate() @safe op)
    {
        try
            op();
        catch (RouteError e)
        {
            assert(e.msg == "andaime: the app is already serving; register routes and middleware before serve (in the build function)", e.msg);
            return;
        }
        assert(0, "expected a RouteError");
    }

    expectRouteError({ app.use((Context ctx, Next n) { n(); }); });
    expectRouteError({ g.use((Context ctx, Next n) { n(); }); });
    expectRouteError({ app.get!("/late", late); });
    expectRouteError({ g.get!("/late", late); });
    expectRouteError({ app.group("/other"); });
    expectRouteError({ g.group("/sub"); });
    expectRouteError({ app.serveOpenApi(); });
    expectRouteError({ app.onError((Context ctx, Exception e) { }); });
    expectRouteError({ app.onNotFound((Context ctx) { }); });
    assert(c.get("/a").status == 200, "the app keeps serving after the refused change");
}

unittest
{
    // the OpenAPI document lists routes registered after serveOpenApi(), and is built before the first request
    auto app = new App;
    app.get!("/early", hi);
    app.serveOpenApi(OpenApiInfo("T", "1"));
    app.get!("/late", late);
    auto g = app.group("/g");
    g.get!("/grouped", hi);
    auto c = TestClient(app);
    auto doc = c.get("/openapi.json").body;
    import std.algorithm : canFind;
    assert(doc.canFind(`"/early"`) && doc.canFind(`"/late"`) && doc.canFind(`"/g/grouped"`), doc);
}
