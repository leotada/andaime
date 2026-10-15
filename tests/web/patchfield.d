/// `PatchField!T` through a real PATCH route: absent leaves a field alone, null clears it, a value sets it; errors keep
/// their `loc`; the OpenAPI schema says "nullable, not required"; a response omits absent fields.
module patchfield_test;

@safe:

import vela;
import vela.web.testing;
import std.json : parseJSON, JSONType;

struct Profile { string name; string nickname; int age; string[] tags; }

struct ProfileUpdate
{
    @minLength(2) PatchField!string name;
    @maxLength(10) PatchField!string nickname;
    @inRange(0, 150) PatchField!int age;
    PatchField!(string[]) tags;
}

/// What changed, as the client sees it: absent fields are left out.
struct Changes { PatchField!string nickname; PatchField!int age; }

final class Store
{
    Profile p = Profile("Ana", "aninha", 30, ["a"]);

    Profile update(JsonBody!ProfileUpdate u)
    {
        if (u.name.hasValue)
            p.name = u.name.value;
        if (u.nickname.isNull)
            p.nickname = null;
        else if (u.nickname.hasValue)
            p.nickname = u.nickname.value;
        if (u.age.isNull)
            p.age = 0;
        else if (u.age.hasValue)
            p.age = u.age.value;
        if (u.tags.isPresent)
            p.tags = u.tags.valueOr(null);
        return p;
    }
}

Changes echoChanges(JsonBody!Changes c) => c.value;

App build(Store s)
{
    auto app = new App;
    app.patch!("/me", (JsonBody!ProfileUpdate u) => s.update(u));
    app.post!("/changes", echoChanges);
    app.serveOpenApi(OpenApiInfo("P", "1"));
    return app;
}

unittest
{
    auto s = new Store;
    auto c = TestClient(build(s));

    // absent: nothing changes
    auto r = c.patch("/me", `{}`);
    assert(r.status == 200 && r.body == `{"name":"Ana","nickname":"aninha","age":30,"tags":["a"]}`, r.body);

    // a value sets, null clears, the rest stays
    r = c.patch("/me", `{"nickname":null,"age":31}`);
    assert(r.body == `{"name":"Ana","nickname":"","age":31,"tags":["a"]}`, r.body);
    r = c.patch("/me", `{"nickname":"ana","tags":null}`);
    assert(r.body == `{"name":"Ana","nickname":"ana","age":31,"tags":[]}`, r.body);

    // invalid values: a 422 with the field's loc; null is never validated
    r = c.patch("/me", `{"name":"A","age":"old","nickname":"abcdefghijk"}`);
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"int_parsing","loc":["body","age"],"msg":"expected an integer between -2147483648 and 2147483647"},`
        ~ `{"type":"string_too_short","loc":["body","name"],"msg":"expected at least 2 characters"},`
        ~ `{"type":"string_too_long","loc":["body","nickname"],"msg":"expected at most 10 characters"}]}`, r.body);
    assert(c.patch("/me", `{"name":null}`).status == 200);
    assert(s.p.name == "Ana", "null on a field the handler does not clear");

    // a response leaves absent fields out and writes null for null ones
    assert(c.post("/changes", `{}`).body == `{}`);
    assert(c.post("/changes", `{"nickname":null,"age":3}`).body == `{"nickname":null,"age":3}`);
}

unittest
{
    // OpenAPI: nullable, never required, the constraints on the value
    auto doc = parseJSON(TestClient(build(new Store)).get("/openapi.json").body);
    auto sch = doc["components"]["schemas"]["ProfileUpdate"];
    assert("required" !in sch, sch.toString);
    auto name = sch["properties"]["name"];
    assert(name["type"].str == "string" && name["nullable"].type == JSONType.true_ && name["minLength"].integer == 2,
        name.toString);
    auto tags = sch["properties"]["tags"];
    assert(tags["type"].str == "array" && tags["nullable"].type == JSONType.true_, tags.toString);
    assert(sch["properties"]["age"]["maximum"].integer == 150);
}
