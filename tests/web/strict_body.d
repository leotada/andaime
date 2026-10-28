/// `@strict` on a JSON body type: an unknown key is a 422 `extra_forbidden` with the key in `loc` (also inside nested
/// objects and array elements); a type without it ignores unknown keys as before. OpenAPI marks strict schemas
/// `additionalProperties: false`.
module strict_body_test 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.json : parseJSON, JSONType;

@strict struct Address { string city; }

@strict struct StrictUser { string name; Address address; Address[] others; }

struct LenientUser { string name; }

App build()
{
    auto app = new App;
    app.post!("/strict", (JsonBody!StrictUser u) => u.value.name);
    app.post!("/lenient", (JsonBody!LenientUser u) => u.value.name);
    app.serveOpenApi(OpenApiInfo("S", "1"));
    return app;
}

unittest
{
    auto c = TestClient(build());
    // a known set of keys passes
    auto ok = c.post("/strict", `{"name":"Ana","address":{"city":"Rio"},"others":[]}`);
    assert(ok.status == 200, ok.body);

    auto r = c.post("/strict", `{"name":"Ana","address":{"city":"Rio"},"others":[],"age":3}`);
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"extra_forbidden","loc":["body","age"],"msg":"Extra inputs are not permitted"}]}`,
        r.body);

    // nested object and array element, and every unknown key is reported (the value is skipped, whatever it is)
    r = c.post("/strict", `{"name":"Ana","x":{"a":[1,2]},"address":{"city":"Rio","zip":1},"others":[{"city":"A"},{"city":"B","zz":0}]}`);
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"extra_forbidden","loc":["body","x"],"msg":"Extra inputs are not permitted"},`
        ~ `{"type":"extra_forbidden","loc":["body","address","zip"],"msg":"Extra inputs are not permitted"},`
        ~ `{"type":"extra_forbidden","loc":["body","others",1,"zz"],"msg":"Extra inputs are not permitted"}]}`, r.body);

    // a key written with an escape is reported by its decoded name
    r = c.post("/strict", `{"name":"Ana","a` ~ "\x5c" ~ `u0062c":1}`);
    assert(r.status == 422 && r.body.length > 0);
    assert(parseJSON(r.body)["detail"][0]["loc"][1].str == "abc", r.body);
}

unittest
{
    auto c = TestClient(build());
    auto r = c.post("/lenient", `{"name":"Ana","age":3}`);
    assert(r.status == 200 && r.body == "Ana", r.body);
}

unittest
{
    auto doc = parseJSON(TestClient(build()).get("/openapi.json").body);
    auto schemas = doc["components"]["schemas"];
    assert(schemas["StrictUser"]["additionalProperties"].type == JSONType.false_, schemas["StrictUser"].toString);
    assert(schemas["Address"]["additionalProperties"].type == JSONType.false_);
    assert("additionalProperties" !in schemas["LenientUser"], schemas["LenientUser"].toString);
}
