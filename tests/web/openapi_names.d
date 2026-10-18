/// OpenAPI details: schema names (collisions, templates, @schemaName), @status and @responds, unique operationIds and the
/// docs page (escaping, integrity).
module openapi_names 2025;

import andaime;
import andaime.web.testing;
import andaime.web.openapi : docsHtml, defaultSwaggerUiBase;
import std.json : parseJSON, JSONValue;
import std.algorithm : canFind;
static import support.models_a;
static import support.models_b;

struct Plain { int x; }
@schemaName("PublicThing") struct Internal { int y; }
struct HTTPError { string mine; }  // collides with the schema andaime defines for @responds

@safe:

support.models_a.User userA() => support.models_a.User(1);
support.models_b.User userB() => support.models_b.User("b");
support.models_a.Page!(support.models_a.User) pageOfA() => support.models_a.Page!(support.models_a.User)();
support.models_a.Page!(support.models_b.User) pageOfB() => support.models_a.Page!(support.models_b.User)();
Internal renamed() => Internal(1);
HTTPError mineError() => HTTPError("x");

@status(201) Plain created(JsonBody!Plain b) => Plain(1);
@status(202) void accepted() {}
@status(204) void gone() {}
WithStatus!Plain dynamic() => withStatus(201, Plain(1));
@status(201) WithStatus!Plain explicit() => withStatus(202, Plain(1)); // the handler's own status wins

@responds(404, "User not found") @responds(409, "Already exists")
Plain guarded(long id)
{
    if (id == 404) throw new HttpError(404, "user not found");
    return Plain(1);
}

class Repo1
{
    @Get("/one/list") string list() => "1";
}
class Repo2
{
    @Get("/two/list") string list() => "2";
}

@system unittest
{
    auto app = new App;
    app.get!("/a", userA);
    app.get!("/b", userB);
    app.get!("/pa", pageOfA);
    app.get!("/pb", pageOfB);
    app.get!("/renamed", renamed);
    app.get!("/mine", mineError);
    app.post!("/created", created);
    app.get!("/accepted", accepted);
    app.get!("/gone", gone);
    app.get!("/dynamic", dynamic);
    app.get!("/explicit", explicit);
    app.get!("/guarded/{id}", guarded);
    app.mount(new Repo1);
    app.mount(new Repo2);
    app.serveOpenApi(OpenApiInfo("T", "1"));
    auto c = TestClient(app);
    auto doc = parseJSON(c.get("/openapi.json").body);
    auto schemas = doc["components"]["schemas"].object;
    // tools/openapi_validate.sh asks for the document to feed it to an independent validator
    import std.process : environment;
    import std.file : write;
    if (auto path = environment.get("ANDAIME_OPENAPI_OUT"))
        write(path, c.get("/openapi.json").body);

    // two User structs from two modules: two schemas, each operation points to its own
    string refOf(string path) { return doc["paths"][path]["get"]["responses"]["200"]["content"]["application/json"]["schema"]["$ref"].str; }
    assert(refOf("/a") == "#/components/schemas/User", refOf("/a"));
    assert(refOf("/b") != refOf("/a") && refOf("/b").canFind("User"), refOf("/b"));
    assert(schemas[refOf("/a")["#/components/schemas/".length .. $]]["properties"].object.keys == ["id"]);
    assert(schemas[refOf("/b")["#/components/schemas/".length .. $]]["properties"].object.keys == ["name"]);

    // template instances: Page_User, with a valid name (letters, digits, . _ -); the two instances do not merge
    assert(refOf("/pa").canFind("Page_User") && refOf("/pb").canFind("Page_User") && refOf("/pa") != refOf("/pb"));
    foreach (name, _; schemas)
        foreach (ch; name)
            assert((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '.' || ch == '_' || ch == '-', name);

    // @schemaName, and a user struct called HTTPError does not clobber andaime's
    assert(refOf("/renamed") == "#/components/schemas/PublicThing");
    assert(refOf("/mine") != "#/components/schemas/HTTPError");
    assert(schemas["HTTPError"]["required"].array[0].str == "detail");

    // @status: dispatch and document agree
    auto r = c.post("/created", `{"x":1}`);
    assert(r.status == 201);
    assert("201" in doc["paths"]["/created"]["post"]["responses"].object);
    assert(c.get("/accepted").status == 202 && "202" in doc["paths"]["/accepted"]["get"]["responses"].object);
    assert(c.get("/gone").status == 204 && "204" in doc["paths"]["/gone"]["get"]["responses"].object);
    assert(c.get("/dynamic").status == 201 && "2XX" in doc["paths"]["/dynamic"]["get"]["responses"].object);
    assert(c.get("/explicit").status == 202, "WithStatus wins over @status");
    assert("201" in doc["paths"]["/explicit"]["get"]["responses"].object);

    // @responds
    auto resp = doc["paths"]["/guarded/{id}"]["get"]["responses"];
    assert(resp["404"]["description"].str == "User not found" && resp["409"]["description"].str == "Already exists");
    assert(resp["404"]["content"]["application/json"]["schema"]["$ref"].str == "#/components/schemas/HTTPError");
    assert("200" in resp.object && "422" in resp.object);
    assert(c.get("/guarded/404").status == 404);

    // operationIds are unique even when two controllers have a method called `list`
    bool[string] ids;
    foreach (path, item; doc["paths"].object)
        foreach (verb, op; item.object)
        {
            auto id = op["operationId"].str;
            assert(id !in ids, "duplicate operationId " ~ id);
            ids[id] = true;
        }
    assert("list" in ids);
}

unittest
{
    // the docs page: the title cannot inject HTML, the pinned CDN files carry integrity hashes, self-hosting drops them
    auto html = docsHtml("/openapi.json", `<script>alert(1)</script> & "co"`);
    assert(!html.canFind("<script>alert") && html.canFind("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;co&quot;"), html);
    assert(html.canFind(`integrity="sha384-`) && html.canFind(`crossorigin="anonymous"`));
    assert(html.canFind(defaultSwaggerUiBase ~ "/swagger-ui-bundle.js"));
    auto own = docsHtml("/openapi.json", "T", "/static/swagger");
    assert(own.canFind(`src="/static/swagger/swagger-ui-bundle.js"`) && !own.canFind("integrity="));
    auto evil = docsHtml(`/x</script><script>alert(1)`, "T");
    assert(!evil.canFind("</script><script>alert"), evil);
}
