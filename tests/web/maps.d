/// JSON objects as `V[string]`: read, written, validated and described.
module maps;

@safe:

import andaime;
import andaime.web.testing;
import std.json : parseJSON;

struct Item { @minLength(2) string code; int qty; }
struct Cart { int[string] counts; Item[string] items; Optional!(string[string]) labels; }

int[string] sums(JsonBody!(int[string]) m) { int[string] r; foreach (k, v; m.value) r[k] = v * 2; return r; }
Cart cart(JsonBody!Cart c) => c.value;
string[string] one() => ["k": "v"];

App build()
{
    auto app = new App;
    app.post!("/sums", sums);
    app.post!("/cart", cart);
    app.get!("/one", one);
    app.serveOpenApi(OpenApiInfo("M", "1"));
    return app;
}

unittest
{
    auto c = TestClient(build());

    // a body that is a map; a single entry has a defined order
    auto r = c.post("/sums", `{"a":1}`);
    assert(r.status == 200 && r.body == `{"a":2}`, r.body);
    r = c.post("/sums", `{}`);
    assert(r.body == `{}`);

    // several entries: compare as JSON, the order is unspecified
    r = c.post("/sums", `{"x":1,"y":2,"z":3}`);
    assert(r.status == 200);
    auto j = parseJSONSafe(r.body);
    assert(j == [`"x":2`, `"y":4`, `"z":6`]);

    // a repeated key: the last one wins
    assert(c.post("/sums", `{"a":1,"a":5}`).body == `{"a":10}`);

    // keys with escapes and non-ASCII
    r = c.post("/sums", `{"café \"x\"":1}`);
    assert(r.body == `{"café \"x\"":2}`, r.body);

    // nested in a struct, with an Optional map; the response is what was sent
    r = c.post("/cart", `{"counts":{"a":1},"items":{"first":{"code":"abc","qty":2}},"labels":{"k":"v"}}`);
    assert(r.status == 200 && r.body == `{"counts":{"a":1},"items":{"first":{"code":"abc","qty":2}},"labels":{"k":"v"}}`, r.body);
    r = c.post("/cart", `{"counts":{},"items":{}}`);
    assert(r.body == `{"counts":{},"items":{},"labels":null}`, r.body);

    // errors name the key in the path
    r = c.post("/cart", `{"counts":{"a":"x","b":2},"items":{"first":{"code":"a","qty":1},"second":5}}`);
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"int_parsing","loc":["body","counts","a"],"msg":"expected an integer between -2147483648 and 2147483647"},`
        ~ `{"type":"string_too_short","loc":["body","items","first","code"],"msg":"expected at least 2 characters"},`
        ~ `{"type":"model_type","loc":["body","items","second"],"msg":"expected an object"}]}`, r.body);
    r = c.post("/cart", `{"counts":[1],"items":{}}`);
    assert(r.status == 422 && r.body == `{"detail":[{"type":"dict_type","loc":["body","counts"],"msg":"expected an object"}]}`, r.body);

    assert(c.get("/one").body == `{"k":"v"}`);
}

/// The members of a flat JSON object, sorted.
private string[] parseJSONSafe(string s)
{
    import std.algorithm : sort;
    import std.array : split;

    auto parts = s[1 .. $ - 1].split(",");
    parts.sort();
    return parts;
}

@system unittest
{
    auto c = TestClient(build());
    auto doc = parseJSON(c.get("/openapi.json").body);
    auto cart = doc["components"]["schemas"]["Cart"]["properties"];
    assert(cart["counts"]["type"].str == "object" && cart["counts"]["additionalProperties"]["type"].str == "integer");
    assert(cart["items"]["additionalProperties"]["$ref"].str == "#/components/schemas/Item");
    auto body_ = doc["paths"]["/sums"]["post"]["requestBody"]["content"]["application/json"]["schema"];
    assert(body_["type"].str == "object" && body_["additionalProperties"]["format"].str == "int32");
}
