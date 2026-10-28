/// `@omitIfAbsent`: an empty `Optional` is left out of the JSON object (on a field, or on the whole struct) instead of
/// written as `null`; OpenAPI drops `nullable` from those fields. Without the attribute the key is `null`, as before.
module omit_if_absent_test 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.json : parseJSON, JSONType;

struct Plain { string id; Optional!string note; }

struct OneField { string id; @omitIfAbsent Optional!string note; Optional!int other; }

@omitIfAbsent struct WholeType { string id; Optional!string note; Optional!int count; }

Plain plain(bool full) => full ? Plain("1", Optional!string("hi")) : Plain("1");
OneField oneField(bool full) => full ? OneField("1", Optional!string("hi"), Optional!int(2)) : OneField("1");
WholeType wholeType(bool full) => full ? WholeType("1", Optional!string("hi"), Optional!int(3)) : WholeType("1");

App build()
{
    auto app = new App;
    app.get!("/plain/{full}", (bool full) => plain(full));
    app.get!("/one/{full}", (bool full) => oneField(full));
    app.get!("/whole/{full}", (bool full) => wholeType(full));
    app.serveOpenApi(OpenApiInfo("O", "1"));
    return app;
}

unittest
{
    auto c = TestClient(build());
    // the default stays: the key is there, null
    assert(c.get("/plain/false").body == `{"id":"1","note":null}`, c.get("/plain/false").body);
    assert(c.get("/plain/true").body == `{"id":"1","note":"hi"}`);
    // on one field: only that field is left out
    assert(c.get("/one/false").body == `{"id":"1","other":null}`, c.get("/one/false").body);
    assert(c.get("/one/true").body == `{"id":"1","note":"hi","other":2}`);
    // on the type: every Optional is
    assert(c.get("/whole/false").body == `{"id":"1"}`, c.get("/whole/false").body);
    assert(c.get("/whole/true").body == `{"id":"1","note":"hi","count":3}`);
}

unittest
{
    auto doc = parseJSON(TestClient(build()).get("/openapi.json").body);
    auto schemas = doc["components"]["schemas"];
    auto plainNote = schemas["Plain"]["properties"]["note"];
    assert(plainNote["nullable"].type == JSONType.true_, plainNote.toString);
    assert("required" in schemas["Plain"] && schemas["Plain"]["required"].toString == `["id"]`);
    auto one = schemas["OneField"]["properties"];
    assert("nullable" !in one["note"], one["note"].toString);
    assert(one["other"]["nullable"].type == JSONType.true_, one["other"].toString);
    auto whole = schemas["WholeType"];
    assert("nullable" !in whole["properties"]["note"] && "nullable" !in whole["properties"]["count"], whole.toString);
    assert(whole["required"].toString == `["id"]`, whole.toString); // only id: an Optional is never required
}
