/// openapi.json generated from the signatures.
module openapi_test 2025;

@safe:

import andaime;
import andaime.web.testing;

enum Order { asc, desc }

struct Address { string city; }

struct NewUser
{
    @minLength(2) @maxLength(60) string name;
    @inRange(0, 150) int age;
    Optional!string email;
    @jsonKey("home") Address address;
    string[] tags;
    @jsonIgnore int secret;
    @optional Order order;
}

struct UserOut { long id; string name; }

@summary("Fetch a user")
UserOut getUser(long id, Header!"X-Trace" trace, bool verbose = false) => UserOut(id, "x");
UserOut[] list(int limit = 20, Optional!string q = Optional!string.init, Order order = Order.asc) => null;
UserOut create(JsonBody!NewUser body_, Context ctx) => UserOut(1, body_.name);
void remove(long id, Local!UserOut me) {}
string files(string rest) => rest;

@system unittest
{
    auto app = new App;
    app.get!("/users/{id}", getUser);
    auto api = app.group("/api");
    api.get!("/users", list);
    api.post!("/users", create);
    api.del!("/users/{id}", remove);
    app.get!("/files/{*rest}", files);
    app.serveOpenApi(OpenApiInfo("Test", "9.9.9"));
    auto c = TestClient(app);

    auto r = c.get("/openapi.json");
    assert(r.status == 200 && r.contentType == "application/json");
    auto j = r.body;

    import std.json : parseJSON, JSONType;
    auto doc = parseJSON(j); // must be valid JSON
    assert(doc["openapi"].str == "3.0.3" && doc["info"]["title"].str == "Test");

    auto get = doc["paths"]["/users/{id}"]["get"];
    assert(get["operationId"].str == "getUser" && get["summary"].str == "Fetch a user");
    bool sawPath, sawHeader, sawQuery;
    foreach (p; get["parameters"].array)
    {
        auto name = p["name"].str;
        if (name == "id") { sawPath = p["in"].str == "path" && p["required"].boolean && p["schema"]["format"].str == "int64"; }
        if (name == "X-Trace") sawHeader = p["in"].str == "header" && p["required"].boolean;
        if (name == "verbose") sawQuery = p["in"].str == "query" && !p["required"].boolean;
    }
    assert(sawPath && sawHeader && sawQuery, j);
    assert(get["responses"]["200"]["content"]["application/json"]["schema"]["$ref"].str == "#/components/schemas/UserOut");
    assert("422" in get["responses"].object);

    auto list = doc["paths"]["/api/users"]["get"];
    foreach (p; list["parameters"].array)
        if (p["name"].str == "limit") assert(!p["required"].boolean);
        else if (p["name"].str == "order") assert(p["schema"]["enum"].array.length == 2);
    assert(list["responses"]["200"]["content"]["application/json"]["schema"]["type"].str == "array");

    auto post = doc["paths"]["/api/users"]["post"];
    assert(post["requestBody"]["required"].boolean);
    assert(post["requestBody"]["content"]["application/json"]["schema"]["$ref"].str == "#/components/schemas/NewUser");

    auto nu = doc["components"]["schemas"]["NewUser"];
    auto props = nu["properties"];
    assert(props["name"]["minLength"].integer == 2 && props["name"]["maxLength"].integer == 60);
    assert(props["age"]["minimum"].integer == 0 && props["age"]["maximum"].integer == 150);
    assert(props["email"]["nullable"].boolean);
    assert("home" in props.object && "address" !in props.object, "@jsonKey");
    assert("secret" !in props.object, "@jsonIgnore");
    assert(props["tags"]["type"].str == "array");
    string[] req;
    foreach (x; nu["required"].array) req ~= x.str;
    assert(req == ["name", "age", "home", "tags"], j);   // Optional and @optional are left out

    // Context and Local do not appear; delete without a body documents 204
    auto del = doc["paths"]["/api/users/{id}"]["delete"];
    assert(del["parameters"].array.length == 1 && "204" in del["responses"].object);
    // {*rest} becomes {rest}
    assert("/files/{rest}" in doc["paths"].object);

    auto d = c.get("/docs");
    assert(d.status == 200 && d.contentType == "text/html; charset=utf-8" && d.body.length > 100);
}

@system unittest // the document without serving: openApiDocument
{
    import std.json : parseJSON;

    auto app = new App;
    app.get!("/users/{id}", getUser);
    app.post!("/users", create);
    app.serveOpenApi(OpenApiInfo("Test", "9.9.9"));
    auto served = TestClient(app).get("/openapi.json").body;
    assert(app.openApiDocument == served, "the same document the route answers");

    // pretty: the same document, one member per line, two spaces, no trailing space
    auto pretty = app.openApiDocument(true);
    assert(parseJSON(pretty) == parseJSON(served) && pretty != served);
    import std.string : splitLines;
    assert(pretty.splitLines[0] == "{" && pretty.splitLines[1] == `  "openapi": "3.0.3",`, pretty[0 .. 40]);
    foreach (line; pretty.splitLines)
        assert(line.length == 0 || line[$ - 1] != ' ', line);

    // an app that never called serveOpenApi still has a document (nothing is routed for it)
    auto quiet = new App;
    quiet.get!("/users/{id}", getUser);
    auto doc = parseJSON(quiet.openApiDocument);
    assert(doc["info"]["title"].str == "API" && "/users/{id}" in doc["paths"].object);
    assert(TestClient(quiet).get("/openapi.json").status == 404);

    // building it freezes the app, like serving does
    bool threw;
    try
        quiet.get!("/late", getUser);
    catch (RouteError)
        threw = true;
    assert(threw);
}

@system unittest // indentJson: strings keep their escapes and punctuation, empty containers stay compact
{
    import andaime.web.openapi : indentJson;
    import std.json : parseJSON;

    enum doc = `{"a":[1,2,{"b":"x, y: \"z\" {}"}],"c":{},"d":[],"e":null,"f":"\\"}`;
    auto pretty = indentJson(doc);
    assert(pretty == "{\n  \"a\": [\n    1,\n    2,\n    {\n      \"b\": \"x, y: \\\"z\\\" {}\"\n    }\n  ],\n"
        ~ "  \"c\": {},\n  \"d\": [],\n  \"e\": null,\n  \"f\": \"\\\\\"\n}", pretty);
    assert(parseJSON(pretty) == parseJSON(doc));
    assert(indentJson("{}") == "{}" && indentJson("[]") == "[]" && indentJson(`"x"`) == `"x"`);
}
