/// Validation errors as the client sees them: FastAPI/Pydantic v2 shape with type codes, array indexes in loc,
/// UTF-8 checks, character-based lengths and the cap on listed errors.
module validation;

@safe:

import vela;
import vela.web.testing;

enum Order { asc, desc }

struct Line { @minLength(3) string code; @inRange(1, 99) int qty; }
struct Cart { Line[] lines; @maxLength(2) string[] notes; }

string search(string q, bool exact = false, Order order = Order.asc, Optional!int page = Optional!int.init)
    => q;

string fromPath(string name, int n) => name;
string needsToken(Header!"X-Token" t) => t.value.idup;
string checkout(JsonBody!Cart cart) => "ok";

App build()
{
    auto app = new App;
    app.get!("/search", search);
    app.get!("/p/{name}/{n}", fromPath);
    app.get!("/tok", needsToken);
    app.post!("/cart", checkout);
    return app;
}

unittest
{
    auto c = TestClient(build());

    // missing query parameter
    auto r = c.get("/search");
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"missing","loc":["query","q"],"msg":"Field required"}]}`, r.body);

    // wrong bool and enum, reported together
    r = c.get("/search?q=a&exact=maybe&order=sideways");
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"bool_parsing","loc":["query","exact"],"msg":"expected true or false"},`
        ~ `{"type":"enum","loc":["query","order"],"msg":"expected one of: asc, desc"}]}`, r.body);

    // the query also accepts 1/0 for bool
    assert(c.get("/search?q=a&exact=1").status == 200);

    // path conversions
    r = c.get("/p/ana/x");
    assert(r.body == `{"detail":[{"type":"int_parsing","loc":["path","n"],`
        ~ `"msg":"expected an integer between -2147483648 and 2147483647"}]}`, r.body);

    // header
    r = c.get("/tok");
    assert(r.body == `{"detail":[{"type":"missing","loc":["header","X-Token"],"msg":"Field required"}]}`, r.body);

    // percent-encoding and UTF-8
    r = c.get("/search?q=%zz");
    assert(r.body == `{"detail":[{"type":"percent_encoding","loc":["query","q"],"msg":"invalid percent-encoding"}]}`, r.body);
    r = c.get("/search?q=%FF");
    assert(r.body == `{"detail":[{"type":"string_unicode","loc":["query","q"],"msg":"invalid UTF-8"}]}`, r.body);
    assert(c.get("/search?q=%C3%A7").status == 200, "valid UTF-8 passes");
}

unittest
{
    auto c = TestClient(build());

    // missing and wrong-typed body
    auto r = c.post("/cart", "");
    assert(r.body == `{"detail":[{"type":"missing","loc":["body"],"msg":"JSON body required"}]}`, r.body);
    r = c.post("/cart", `{"lines":[`);
    assert(r.status == 422 && r.body == `{"detail":[{"type":"json_invalid","loc":["body"],"msg":"invalid JSON at byte 10"}]}`, r.body);

    // nested path with an array index, and a character-based length ("çã" is 2 characters in 4 bytes)
    r = c.post("/cart", `{"lines":[{"code":"abc","qty":1},{"code":"çã","qty":100}],"notes":["a","b","c"]}`);
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"string_too_short","loc":["body","lines",1,"code"],"msg":"expected at least 3 characters"},`
        ~ `{"type":"less_than_equal","loc":["body","lines",1,"qty"],"msg":"must be <= 99"},`
        ~ `{"type":"too_long","loc":["body","notes"],"msg":"expected at most 2 items"}]}`, r.body);
    assert(c.post("/cart", `{"lines":[{"code":"çãõ","qty":1}],"notes":[]}`).status == 200);
}

unittest
{
    // 17 or more errors: 16 listed plus one summary entry
    auto c = TestClient(build());
    string js = `{"lines":[`;
    foreach (i; 0 .. 20)
        js ~= (i ? `,` : ``) ~ `{"code":"ab","qty":1}`;
    js ~= `],"notes":[]}`;
    auto r = c.post("/cart", js);
    assert(r.status == 422);
    import std.algorithm : count;
    import std.string : indexOf;
    assert(r.body.count(`"type":"string_too_short"`) == 16, r.body);
    assert(r.body.indexOf(`{"type":"too_many_errors","loc":[],"msg":"4 more errors not shown"}`) > 0, r.body);
}
