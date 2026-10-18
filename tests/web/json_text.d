/// `Json!T` through routes: plain JSON in a body and in a response (never a string holding JSON), JSON text in a query
/// parameter, and the schema of `T` in OpenAPI.
module json_text_test 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.json : parseJSON;

struct Tag { long id; string name; }
struct Task { long id; Json!(Tag[]) tags; Optional!(Json!JsonValue) meta; }

Task echo(JsonBody!Task t) => t.value;
string count(Json!(Tag[]) filter) => filter.length == 2 ? "two" : "other";

App build()
{
    auto app = new App;
    app.post!("/tasks", echo);
    app.get!("/count", count);
    app.serveOpenApi(OpenApiInfo("J", "1"));
    return app;
}

unittest
{
    auto c = TestClient(build());
    auto r = c.post("/tasks", `{"id":1,"tags":[{"id":2,"name":"red"}],"meta":{"a":[1]}}`,
        hdr("Content-Type", "application/json"));
    assert(r.status == 200 && r.body == `{"id":1,"tags":[{"id":2,"name":"red"}],"meta":{"a":[1]}}`, r.body);

    // the inner type's errors, with their path
    r = c.post("/tasks", `{"id":1,"tags":[{"id":"x","name":"red"}]}`, hdr("Content-Type", "application/json"));
    assert(r.status == 422 && r.body == `{"detail":[{"type":"int_parsing","loc":["body","tags",0,"id"],`
        ~ `"msg":"expected an integer between -9223372036854775808 and 9223372036854775807"}]}`, r.body);

    // a query parameter holds JSON text
    assert(c.get(`/count?filter=[{"id":1,"name":"a"},{"id":2,"name":"b"}]`).body == "two");
    r = c.get("/count?filter=nope");
    assert(r.status == 422 && r.body == `{"detail":[{"type":"value_error","loc":["query","filter"],`
        ~ `"msg":"expected JSON for Tag[]"}]}`, r.body);
}

@system unittest // (std.json's object accessor is @system)
{
    auto c = TestClient(build());
    auto task = parseJSON(c.get("/openapi.json").body)["components"]["schemas"]["Task"]["properties"];
    assert(task["tags"].toString == `{"items":{"$ref":"#\/components\/schemas\/Tag"},"type":"array"}`, task["tags"].toString);
    assert(task["meta"].toString == `{"nullable":true}`, "an optional any-value schema stays valid JSON");
}
