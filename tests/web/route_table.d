/// `Group.mount` (a controller under a group's prefix, with the group's middleware) and `App.routeTable` (method, path
/// and handler name of every route, in registration order).
module route_table;

@safe:

import andaime;
import andaime.web.testing;
import std.algorithm : canFind;
import std.conv : to;
import std.string : lineSplitter, split;

string health() => "ok";

WebSocket echo()
{
    return WebSocket((scope WsConn ws) @system {
        foreach (msg; ws)
            ws.send(msg.text);
    });
}

final class Users
{
    string[] names = ["ana"];

    @Get("/users") string[] list() => names;

    @Post("/users") @status(201)
    string add(JsonBody!Name b)
    {
        names ~= b.name;
        return b.name;
    }

    @Get("/") string root() => "users root";

    @Ws("/live") WebSocket live() => echo();
}

struct Name { string name; }

/// The group's middleware: marks every response that went through it.
void tagged(Context ctx, Next next)
{
    ctx.setHeader("X-Group", "api");
    next();
}

enum lambdaLine = __LINE__ + 6; // the line of the lambda registered in buildApp

App buildApp()
{
    auto app = new App;
    app.get!("/health", health);
    app.get!("/hello", () => "hello");
    app.ws!("/echo", echo);
    auto api = app.group("/api/v1");
    api.use(&tagged);
    api.mount(new Users);
    app.serveOpenApi();
    return app;
}

unittest // Group.mount: the paths are relative to the prefix and the group's middleware runs
{
    auto c = TestClient(buildApp());
    auto r = c.get("/api/v1/users");
    assert(r.status == 200 && r.body == `["ana"]`, r.body);
    assert(r.header("X-Group") == "api");
    r = c.post("/api/v1/users", `{"name":"bia"}`);
    assert(r.status == 201, r.body);
    assert(c.get("/api/v1/users").body == `["ana","bia"]`);
    r = c.get("/api/v1"); // "/" under a group is the prefix itself
    assert(r.status == 200 && r.body == "users root" && r.header("X-Group") == "api", r.body);
    assert(c.get("/users").status == 404); // not mounted at the root
    r = c.get("/health");
    assert(r.status == 200 && r.header("X-Group").length == 0); // outside the group: no group middleware
}

unittest // the mounted operations are in the OpenAPI document under their full paths
{
    auto c = TestClient(buildApp());
    auto doc = c.get("/openapi.json").body;
    assert(doc.canFind(`"/api/v1/users":`), doc);
    assert(doc.canFind(`"/api/v1":`), doc);
    assert(!doc.canFind(`"/users":`), doc);
}

unittest // routeTable: one aligned line per route, in registration order, with the handler's name
{
    auto table = buildApp().routeTable();
    string[] lines;
    foreach (l; table.lineSplitter)
        lines ~= l;
    assert(lines.length == 9, table);
    string[][] cols;
    foreach (l; lines)
        cols ~= l.split;
    assert(cols[0] == ["GET", "/health", "route_table.health"], table);
    assert(cols[1] == ["GET", "/hello", __FILE__ ~ ":" ~ lambdaLine.to!string], table);
    assert(cols[2] == ["GET", "/echo", "route_table.echo", "(WebSocket)"], table);
    assert(cols[3] == ["GET", "/api/v1/users", "route_table.Users.list"], table);
    assert(cols[4] == ["POST", "/api/v1/users", "route_table.Users.add"], table);
    assert(cols[5] == ["GET", "/api/v1", "route_table.Users.root"], table);
    assert(cols[6] == ["GET", "/api/v1/live", "route_table.Users.live", "(WebSocket)"], table);
    assert(cols[7] == ["GET", "/openapi.json", "(andaime:", "OpenAPI)"], table);
    assert(cols[8] == ["GET", "/docs", "(andaime:", "Swagger", "UI)"], table);
    // the handler column starts at the same place on every line
    immutable at = lines[0].canFind("route_table.health") ? lines[0].length - "route_table.health".length : 0;
    foreach (l; lines)
        assert(l.length > at && l[at - 1] == ' ' && l[at] != ' ', table);
}

unittest // a route registered by hand without a name shows "-"
{
    auto app = new App;
    app.register(Method.GET, "/raw", (Context ctx) { ctx.text("raw"); });
    assert(app.routeTable() == "GET     /raw  -\n", app.routeTable());
}
