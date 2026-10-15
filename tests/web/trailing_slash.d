/// `TrailingSlash.matchBoth` on the app and on groups: `/x/` and `/x` reach the same route, with no redirect.
module trailing_slash_test;

@safe:

import vela;
import vela.web.testing;
import std.json : parseJSON;

string list() => "list";
string show(long id) => "show " ~ (cast(int) id == id ? "ok" : "");
string created(JsonBody!Item it) => "created " ~ it.name;
string explicitSlash(long id) => "explicit";
string files(string path) => "file " ~ path;
string inner() => "inner";
string strictOne() => "strict";

struct Item { string name; }

App build(TrailingSlash policy)
{
    auto app = new App;
    app.trailingSlash = policy;
    app.get!("/api/tasks", list);
    app.post!("/api/tasks", created);
    app.get!("/api/tasks/{id}", show);
    app.get!("/api/tasks/{id}/", explicitSlash); // an explicit route keeps its form
    app.get!("/files/{*path}", files);
    auto g = app.group("/strict");
    g.trailingSlash = TrailingSlash.strict;
    g.get!("/one", strictOne);
    g.group("/deeper").get!("/x", inner); // inherits strict from its parent group
    app.serveOpenApi(OpenApiInfo("T", "1"));
    return app;
}

unittest
{
    auto c = TestClient(build(TrailingSlash.matchBoth));
    assert(c.get("/api/tasks").body == "list");
    assert(c.get("/api/tasks/").body == "list", "the other form, no redirect");
    assert(c.get("/api/tasks/?page=2").body == "list");
    auto r = c.post("/api/tasks/", `{"name":"a"}`, hdr("Content-Type", "application/json"));
    assert(r.status == 200 && r.body == "created a", "POST keeps its body: no 308");
    assert(c.get("/api/tasks/7").body == "show ok");
    assert(c.get("/api/tasks/7/").body == "explicit");
    assert(c.get("/files/a/b/").body == "file a/b/", "a {*rest} route already takes any tail");
    assert(c.get("/").status == 404);

    // a strict group (and its subgroup) keeps the slash significant
    assert(c.get("/strict/one").body == "strict");
    assert(c.get("/strict/one/").status == 404);
    assert(c.get("/strict/deeper/x/").status == 404);

    // 405 still names the methods of the route
    r = c.request(Method.DELETE, "/api/tasks/", null); // (the explicit null: DMD 2.109 crashes on the default before `...`)
    assert(r.status == 405 && r.header("Allow") == "GET, POST", r.header("Allow"));
}

@system unittest // (std.json's object accessor is @system)
{
    auto c = TestClient(build(TrailingSlash.matchBoth));
    auto paths = parseJSON(c.get("/openapi.json").body)["paths"].object;
    assert("/api/tasks" in paths && "/api/tasks/" !in paths, "OpenAPI shows the registered form only");
}

unittest
{
    // strict (the default) and redirect behave as before
    auto c = TestClient(build(TrailingSlash.strict));
    assert(c.get("/api/tasks/").status == 404);
    c = TestClient(build(TrailingSlash.redirect));
    auto r = c.get("/api/tasks/?page=2");
    assert(r.status == 308 && r.header("Location") == "/api/tasks?page=2");

    // a group cannot redirect
    auto app = new App;
    bool threw;
    try
        app.group("/g").trailingSlash = TrailingSlash.redirect;
    catch (RouteError e)
        threw = true;
    assert(threw);

    // a group can turn matchBoth on under a strict app
    app = new App;
    auto g = app.group("/api");
    g.trailingSlash = TrailingSlash.matchBoth;
    g.get!("/tasks", list);
    app.get!("/other", list);
    c = TestClient(app);
    assert(c.get("/api/tasks/").body == "list");
    assert(c.get("/other/").status == 404);
}
