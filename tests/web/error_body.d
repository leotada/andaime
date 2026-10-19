/// `App.errorBody`: one function shapes mapped exceptions, `HttpError`, 422, 404, 405 and 500; the specific hooks keep
/// priority; `mapError` keeps the original exception; OpenAPI documents the body; `problemDetails` is RFC 9457.
module error_body 2025;

@safe:

import andaime;
import andaime.web.testing;

class DomainError : Exception
{
    string code;
    this(string msg, string code) { super(msg); this.code = code; }
}

final class NotFound : DomainError { this(string msg) { super(msg, "not_found"); } }
final class Conflict : DomainError { this(string msg) { super(msg, "conflict"); } }
final class Teapot : Exception { this() { super("short and stout"); } }

struct ApiError { string message; string code; }
struct NewUser { @minLength(2) string name; }

@responds(404, "No such user")
string getUser(long id)
{
    if (id == 1)
        throw new NotFound("user not found");
    if (id == 2)
        throw new HttpError(403, "not yours");
    if (id == 3)
        throw new Exception("database password is hunter2");
    if (id == 4)
        throw new Conflict("taken");
    if (id == 5)
        throw new Teapot;
    return "ok";
}

string create(JsonBody!NewUser u) => u.name;

ApiError render(ref const ErrorInfo e)
{
    auto d = cast(const DomainError) e.exception;
    string code = d !is null ? d.code : e.status == 404 ? "route_not_found" : e.status == 422 ? "invalid"
        : e.status == 500 ? (e.exception !is null ? "crash" : "?") : "http_" ~ (e.status == 405 ? "405" : "other");
    return ApiError(e.message, code);
}

App build()
{
    auto app = new App;
    app.mapError!NotFound(404);
    app.mapError!Conflict(409, (Conflict c) => ApiError("conflict: " ~ c.msg, "mapped_" ~ c.code)); // its own body
    app.mapError!Teapot(418);
    app.errorBody(&render);
    app.get!("/users/{id}", getUser);
    app.post!("/users", create);
    app.serveOpenApi(OpenApiInfo("T", "1"));
    return app;
}

unittest
{
    auto c = TestClient(build());
    auto r = c.get("/users/1");
    assert(r.status == 404 && r.body == `{"message":"user not found","code":"not_found"}`, r.body);
    r = c.get("/users/2");
    assert(r.status == 403 && r.body == `{"message":"not yours","code":"http_other"}`, r.body);
    r = c.get("/users/3");
    assert(r.status == 500 && r.body == `{"message":"internal error","code":"crash"}`, "the message never leaks: " ~ r.body);
    r = c.get("/users/4");
    assert(r.status == 409 && r.body == `{"message":"conflict: taken","code":"mapped_conflict"}`, r.body);
    r = c.get("/users/5");
    assert(r.status == 418 && r.body == `{"message":"short and stout","code":"http_other"}`, r.body);
    r = c.get("/nowhere");
    assert(r.status == 404 && r.body == `{"message":"not found","code":"route_not_found"}`, r.body);
    r = c.del("/users/1");
    assert(r.status == 405 && r.body == `{"message":"method not allowed","code":"http_405"}`, r.body);
    r = c.post("/users", `{"name":"A"}`);
    assert(r.status == 422 && r.body == `{"message":"body.name: expected at least 2 characters","code":"invalid"}`,
        r.body);
    assert(r.contentType == "application/json");

    // OpenAPI: the documented errors carry the body's schema
    auto doc = c.get("/openapi.json").body;
    assert(contains(doc, `"HTTPError":{"$ref":"#/components/schemas/ApiError"}`) || contains(doc, `"HTTPError":{"type":"object","properties":{"message"`),
        doc);
    assert(contains(doc, `"422":{"description":"Validation error","content":{"application/json":{"schema":`), doc);
    assert(!contains(doc, `HTTPValidationError`), doc);
}

// the specific hooks keep priority over errorBody; onError sees the mapped exception as HttpError.cause
unittest
{
    auto app = new App;
    app.mapError!NotFound(404);
    app.errorBody(&render);
    app.onNotFound((Context ctx) { ctx.text("custom 404", 404); });
    app.onValidationError((Context ctx, ValidationErrors errs) { ctx.text("custom 422", 400); });
    string seen;
    app.onError((Context ctx, Exception e) {
        auto he = cast(HttpError) e;
        seen = he is null ? "plain" : (he.cause is null ? "no cause" : (cast(NotFound) he.cause).code);
        ctx.text("handled", he is null ? 500 : he.status);
    });
    app.get!("/users/{id}", getUser);
    app.post!("/users", create);
    auto c = TestClient(app);
    assert(c.get("/nowhere").body == "custom 404");
    assert(c.post("/users", `{"name":"A"}`).body == "custom 422");
    auto r = c.get("/users/1");
    assert(r.status == 404 && r.body == "handled" && seen == "not_found", seen);
}

// RFC 9457 problem details, with its media type
unittest
{
    auto app = new App;
    app.mapError!NotFound(404);
    app.errorBody(&problemDetails, problemJson);
    app.get!("/users/{id}", getUser);
    app.post!("/users", create);
    app.serveOpenApi(OpenApiInfo("T", "1"));
    auto c = TestClient(app);
    auto r = c.get("/users/1");
    assert(r.status == 404 && r.contentType == "application/problem+json");
    assert(r.body == `{"type":"about:blank","title":"Not Found","status":404,"detail":"user not found","errors":null}`, r.body);
    r = c.post("/users", `{"name":"A"}`);
    assert(r.status == 422 && contains(r.body, `"errors":[{"location":"body","field":"name","type":"string_too_short",`),
        r.body);
    assert(contains(c.get("/openapi.json").body, `"application/problem+json"`));
}

// without errorBody nothing changes
unittest
{
    auto app = new App;
    app.mapError!NotFound(404);
    app.get!("/users/{id}", getUser);
    auto c = TestClient(app);
    assert(c.get("/users/1").body == `{"detail":"user not found"}`);
    assert(c.get("/nowhere").body == `{"detail":"not found"}`);
}

bool contains(string s, string part) pure
{
    if (part.length > s.length)
        return false;
    foreach (i; 0 .. s.length - part.length + 1)
        if (s[i .. i + part.length] == part)
            return true;
    return false;
}
