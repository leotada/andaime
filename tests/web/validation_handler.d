/// `onValidationError`: a custom answer for every way binding can fail, group overrides, controllers, the OpenAPI
/// document, and the default 422 left unchanged when no handler is set.
module validation_handler 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.json : parseJSON;
import std.conv : to;

/// A text type for path segments: 8 hex digits.
struct Hex8
{
    string text;

    static bool fromString(scope const(char)[] t, out Hex8 v)
    {
        if (t.length != 8)
            return false;
        foreach (c; t)
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
                return false;
        v.text = t.idup;
        return true;
    }

    void toString(scope void delegate(scope const(char)[]) @safe sink) const { sink(text); }
}

struct Message { string message; }
struct Item { @minLength(2) string code; int qty; }
struct Order { Item[] items; }
struct Login { @minLength(3) string user; int age; }

string byId(Hex8 id) => id.text;
string search(string q, int limit = 10) => q;
string tok(Header!"X-Token" t) => t.value;
string sess(Cookie!"sid" s) => s.value;
string ids(int[] id) => id.length.to!string;
string order(JsonBody!Order o) => o.items.length.to!string;
string login(Form!Login f) => f.user;
string upload(Form!Login f) => f.user;

/// "source:dotted:type" for each error, then "+dropped".
string summary(ValidationErrors errors)
{
    string r;
    foreach (ref e; errors.items)
        r ~= (r.length ? " " : "") ~ e.source.to!string ~ ":" ~ e.dotted ~ ":" ~ e.type;
    if (errors.dropped)
        r ~= " +" ~ errors.dropped.to!string;
    return r;
}

void routes(App app)
{
    app.get!("/items/{id}", byId);
    app.get!("/search", search);
    app.get!("/tok", tok);
    app.get!("/sess", sess);
    app.get!("/ids", ids);
    app.post!("/order", order);
    app.post!("/login", login);
}

App custom()
{
    auto app = new App;
    app.onValidationError((Context ctx, ValidationErrors errors) {
        if (errors.has(ErrorSource.path))
            return ctx.json(Message("not found"), 404);
        ctx.json(Message(summary(errors)), 400);
    });
    routes(app);
    return app;
}

private string msg(TestResponse r) => parseJSON(r.body)["message"].str;

unittest
{
    auto c = TestClient(custom());

    // a path parameter that does not parse is a 404, as with routers that type their segments
    auto r = c.get("/items/zz");
    assert(r.status == 404 && r.body == `{"message":"not found"}`, r.body);
    assert(c.get("/items/0123abcd").body == "0123abcd");

    // query: missing, wrong type, list index
    r = c.get("/search");
    assert(r.status == 400 && msg(r) == "query:q:missing", r.body);
    r = c.get("/search?q=a&limit=x");
    assert(msg(r) == "query:limit:int_parsing", r.body);
    r = c.get("/ids?id=1&id=x");
    assert(msg(r) == "query:id.1:int_parsing", r.body);

    // header and cookie
    assert(msg(c.get("/tok")) == "header:X-Token:missing");
    assert(msg(c.get("/sess")) == "cookie:sid:missing");

    // JSON body: missing, malformed, wrong types deep inside
    r = c.post("/order", "");
    assert(r.status == 400 && msg(r) == "jsonBody::missing", r.body);
    assert(msg(c.post("/order", `{"items":[`)) == "jsonBody::json_invalid");
    r = c.post("/order", `{"items":[{"code":"ab","qty":1},{"code":"x","qty":"no"}]}`);
    assert(msg(r) == "jsonBody:items.1.qty:int_parsing jsonBody:items.1.code:string_too_short", r.body);

    // forms, urlencoded and multipart, are their own source
    auto form = hdr("Content-Type", "application/x-www-form-urlencoded");
    assert(msg(c.post("/login", "user=al&age=x", form)) == "form:user:string_too_short form:age:int_parsing");
    auto mp = hdr("Content-Type", "multipart/form-data; boundary=z");
    r = c.post("/login", "--z\r\nContent-Disposition: form-data; name=\"user\"\r\n\r\nal\r\n--z--\r\n", mp);
    assert(msg(r) == "form:user:string_too_short form:age:missing", r.body);

    // framing errors are not field errors: they stay HttpErrors (onError), with the same status as before
    r = c.post("/login", "user=abc&age=1", hdr("Content-Type", "text/plain"));
    assert(r.status == 415, r.body);
    r = c.post("/login", "--z--\r\n", hdr("Content-Type", "multipart/form-data"));
    assert(r.status == 400 && r.body == `{"detail":"multipart body has no boundary"}`, r.body);

    // more errors than fit: the count of the rest
    string js = `{"items":[`;
    foreach (i; 0 .. 20)
        js ~= (i ? `,` : ``) ~ `{"code":"a","qty":1}`;
    r = c.post("/order", js ~ `]}`);
    assert(msg(r)[$ - 3 .. $] == " +4", r.body);

    // a valid request is untouched
    assert(c.get("/search?q=ok").body == "ok");
}

unittest
{
    // with no handler, the default 422 stays byte for byte
    auto app = new App;
    routes(app);
    auto c = TestClient(app);
    auto r = c.get("/items/zz");
    assert(r.status == 422 && r.body == `{"detail":[{"type":"value_error","loc":["path","id"],"msg":"invalid Hex8"}]}`, r.body);
    assert(c.get("/search").body == `{"detail":[{"type":"missing","loc":["query","q"],"msg":"Field required"}]}`);
}

unittest
{
    // a handler that writes only a body answers 422; one that falls back gets the default body; one that throws goes
    // to onError like any handler failure
    auto app = new App;
    app.onValidationError((Context ctx, ValidationErrors errors) { ctx.response.body.put("bad"); });
    app.get!("/a", search);
    auto api = app.group("/fallback");
    api.onValidationError((Context ctx, ValidationErrors errors) { writeDefaultValidationErrors(ctx); });
    api.get!("/a", search);
    auto th = app.group("/throws");
    th.onValidationError((Context ctx, ValidationErrors errors) { throw new HttpError(409, "conflict"); });
    th.get!("/a", search);
    auto c = TestClient(app);
    auto r = c.get("/a");
    assert(r.status == 422 && r.body == "bad", r.body);
    r = c.get("/fallback/a");
    assert(r.status == 422 && r.body == `{"detail":[{"type":"missing","loc":["query","q"],"msg":"Field required"}]}`, r.body);
    r = c.get("/throws/a");
    assert(r.status == 409 && r.body == `{"detail":"conflict"}`, r.body);
}

unittest
{
    // the nearest group wins; subgroups inherit; the app's handler covers the rest, registered before or after
    auto app = new App;
    app.get!("/root", search);
    auto v1 = app.group("/v1");
    v1.get!("/s", search);
    auto inner = v1.group("/inner");
    inner.get!("/s", search);
    auto v2 = app.group("/v2");
    v2.get!("/s", search);
    v1.onValidationError((Context ctx, ValidationErrors e) { ctx.text("v1", 400); });
    app.onValidationError((Context ctx, ValidationErrors e) { ctx.text("app", 400); });
    auto c = TestClient(app);
    assert(c.get("/root").body == "app");
    assert(c.get("/v1/s").body == "v1");
    assert(c.get("/v1/inner/s").body == "v1");
    assert(c.get("/v2/s").body == "app");
}

class Users
{
    @Get("/users/{id}") string get(Hex8 id) => id.text;
}

void systemHandler(Context ctx, ValidationErrors errors) @system
{
    int* p = new int; // @system code is allowed here, like in onError
    ctx.text("system", 400);
}

unittest
{
    // mounted controllers use the app's handler; a plain function (even @system) works too
    auto app = new App;
    app.onValidationError(&systemHandler);
    app.mount(new Users);
    auto c = TestClient(app);
    auto r = c.get("/users/nope");
    assert(r.status == 400 && r.body == "system", r.body);
}

unittest
{
    // OpenAPI: the default 422; a declared status and schema; a generic 4XX when nothing is declared
    auto plain = new App;
    plain.get!("/search", search);
    plain.serveOpenApi(OpenApiInfo("T", "1"));
    auto doc = parseJSON(TestClient(plain).get("/openapi.json").body);
    auto resp = doc["paths"]["/search"]["get"]["responses"];
    assert("422" in resp && resp["422"]["content"]["application/json"]["schema"]["$ref"].str
        == "#/components/schemas/HTTPValidationError");

    auto declared = new App;
    declared.onValidationError!Message(400, (Context ctx, ValidationErrors e) { ctx.json(Message("x"), 400); },
        "Invalid request");
    declared.get!("/search", search);
    auto free = declared.group("/free");
    free.onValidationError((Context ctx, ValidationErrors e) { ctx.text("x", 404); });
    free.get!("/search", search);
    declared.get!("/none", () => "none"); // cannot fail: no error entry at all
    declared.serveOpenApi(OpenApiInfo("T", "1"));
    doc = parseJSON(TestClient(declared).get("/openapi.json").body);
    resp = doc["paths"]["/search"]["get"]["responses"];
    assert("422" !in resp && resp["400"]["description"].str == "Invalid request", resp.toString);
    assert(resp["400"]["content"]["application/json"]["schema"]["$ref"].str == "#/components/schemas/Message");
    assert("Message" in doc["components"]["schemas"] && "HTTPValidationError" !in doc["components"]["schemas"]);
    resp = doc["paths"]["/free/search"]["get"]["responses"];
    assert("4XX" in resp && "content" !in resp["4XX"] && "422" !in resp, resp.toString);
    resp = doc["paths"]["/none"]["get"]["responses"];
    assert("400" !in resp && "4XX" !in resp, resp.toString);
}

unittest
{
    // the handler's status must be an HTTP status, and nothing can change after the app starts
    auto app = new App;
    bool threw;
    try
        app.onValidationError!Message(42, (Context ctx, ValidationErrors e) {});
    catch (RouteError)
        threw = true;
    assert(threw);
    app.get!("/search", search);
    TestClient(app).get("/search?q=a");
    threw = false;
    try
        app.onValidationError((Context ctx, ValidationErrors e) {});
    catch (RouteError)
        threw = true;
    assert(threw);
}
