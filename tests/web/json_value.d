/// `JsonValue` through real routes: as the whole body, as a DTO field, in a map with mixed values, as a return value; its
/// errors (syntax, depth, UTF-8) as 422 entries; OpenAPI's "any value".
module json_value_test;

@safe:

import vela;
import vela.web.testing;
import std.json : parseJSON;
import std.conv : to;

/// Keys validated at run time against a schema, with a bool, a string or null per key.
immutable string[] knownSettings = ["dark_mode", "language", "timezone"];

string settings(JsonBody!(JsonValue[string]) body_)
{
    string r;
    foreach (k; knownSettings)
        if (auto v = k in body_.value)
            r ~= k ~ "=" ~ (v.isBool ? v.asBool.to!string : v.isString ? v.asString : v.isNull ? "null" : "?") ~ ";";
    return r;
}

struct Event { string name; @optional JsonValue payload; }

string event(JsonBody!Event e) => e.name ~ ":" ~ e.payload.toString;

JsonValue echo(JsonBody!JsonValue v) => v.value;

JsonValue built()
{
    auto o = JsonValue.emptyObject;
    o["ok"] = true;
    o["count"] = 2;
    o["items"] = JsonValue([JsonValue("a"), JsonValue(null)]);
    return o;
}

App build()
{
    auto app = new App;
    app.post!("/settings", settings);
    app.post!("/event", event);
    app.post!("/echo", echo);
    app.get!("/built", built);
    app.serveOpenApi(OpenApiInfo("J", "1"));
    return app;
}

unittest
{
    auto c = TestClient(build());

    // a map with mixed value types per key
    auto r = c.post("/settings", `{"dark_mode":true,"language":"pt-BR","timezone":null,"other":[1]}`);
    assert(r.status == 200 && r.body == "dark_mode=true;language=pt-BR;timezone=null;", r.body);

    // a DTO field: any value, kept in order; absent with @optional
    assert(c.post("/event", `{"name":"x","payload":{"b":[1,2.5,"s"],"a":null}}`).body == `x:{"b":[1,2.5,"s"],"a":null}`);
    assert(c.post("/event", `{"name":"y"}`).body == "y:null");

    // the whole body, returned as is (key order kept)
    r = c.post("/echo", `{"z":1,"a":{"y":[true,false]},"m":-0.5}`);
    assert(r.status == 200 && r.body == `{"z":1,"a":{"y":[true,false]},"m":-0.5}`, r.body);
    assert(r.contentType == "application/json", r.contentType);
    assert(c.get("/built").body == `{"ok":true,"count":2,"items":["a",null]}`);

    // errors: syntax, nesting, invalid UTF-8 with its path, a missing body
    r = c.post("/echo", `{"a":[1,}`);
    assert(r.status == 422 && r.body == `{"detail":[{"type":"json_invalid","loc":["body"],"msg":"invalid JSON at byte 8"}]}`, r.body);
    string deep;
    foreach (i; 0 .. 65)
        deep ~= "[";
    r = c.post("/echo", deep);
    assert(r.status == 422 && r.body == `{"detail":[{"type":"json_invalid","loc":["body"],"msg":"JSON nested deeper than 64 levels at byte 64"}]}`,
        r.body);
    r = c.post("/event", "{\"name\":\"x\",\"payload\":{\"k\":[\"\xff\"]}}");
    assert(r.status == 422 && r.body == `{"detail":[{"type":"string_unicode","loc":["body","payload","k",0],"msg":"invalid UTF-8"}]}`,
        r.body);
    assert(c.post("/echo", "").status == 422);
}

unittest
{
    // OpenAPI: a JsonValue is any value ({}); a map of them is an object of any values
    auto doc = parseJSON(TestClient(build()).get("/openapi.json").body);
    auto ev = doc["components"]["schemas"]["Event"]["properties"]["payload"];
    assert(ev.toString == `{}`, ev.toString);
    auto sb = doc["paths"]["/settings"]["post"]["requestBody"]["content"]["application/json"]["schema"];
    assert(sb.toString == `{"additionalProperties":{},"type":"object"}`, sb.toString);
}
