/// `Query!T` (a struct from the query string) and `Form!T` (from a urlencoded body).
module models_test;

@safe:

import vela;
import vela.web.testing;
import std.json : parseJSON;
import std.conv : to;

enum Sort { name, date }

struct Filters
{
    @minLength(2) string q;                       // required
    @jsonKey("page_size") @inRange(1, 100) int pageSize = 20; // optional: has an initializer
    Optional!Sort sort;
    string[] tag;
    @optional bool exact;
}

struct Login { @minLength(3) string user; string password; Optional!string note; }

string list(Query!Filters f)
{
    return f.q ~ "/" ~ f.pageSize.to!string ~ "/" ~ (f.sort.has ? f.sort.get.to!string : "-") ~ "/" ~ f.tag.length.to!string
        ~ "/" ~ (f.exact ? "exact" : "fuzzy");
}

string login(Form!Login f) => f.user ~ ":" ~ f.password ~ ":" ~ f.note.getOr("-");

string both(string a, Query!Filters f) => a ~ f.q;

App build()
{
    auto app = new App;
    app.get!("/list", list);
    app.post!("/login", login);
    app.get!("/both/{a}", both);
    app.serveOpenApi(OpenApiInfo("Q", "1"));
    return app;
}

unittest
{
    auto c = TestClient(build());

    // binding: names, defaults, enums, lists, bool
    assert(c.get("/list?q=boots").body == "boots/20/-/0/fuzzy");
    assert(c.get("/list?q=boots&page_size=50&sort=date&tag=a&tag=b&exact=true").body == "boots/50/date/2/exact");
    assert(c.get("/list?q=caf%C3%A9+bar").body == "café bar/20/-/0/fuzzy", "percent-decoding and '+'");
    assert(c.get("/both/x?q=yy").body == "xyy", "a model next to ordinary parameters");

    // errors: the same format, one entry per problem, with the external name
    auto r = c.get("/list?page_size=500&sort=size&tag=ok&exact=maybe");
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"missing","loc":["query","q"],"msg":"Field required"},`
        ~ `{"type":"less_than_equal","loc":["query","page_size"],"msg":"must be <= 100"},`
        ~ `{"type":"enum","loc":["query","sort"],"msg":"expected one of: name, date"},`
        ~ `{"type":"bool_parsing","loc":["query","exact"],"msg":"expected true or false"}]}`, r.body);
    r = c.get("/list?q=x");
    assert(r.status == 422 && r.body == `{"detail":[{"type":"string_too_short","loc":["query","q"],"msg":"expected at least 2 characters"}]}`, r.body);
    r = c.get("/list?q=ok&page_size=abc");
    assert(r.body == `{"detail":[{"type":"int_parsing","loc":["query","page_size"],"msg":"expected an integer between -2147483648 and 2147483647"}]}`, r.body);
    r = c.get("/list?q=ok&tag=a&tag=%FF");
    assert(r.body == `{"detail":[{"type":"string_unicode","loc":["query","tag",1],"msg":"invalid UTF-8"}]}`, r.body);
}

unittest
{
    auto c = TestClient(build());
    auto ct = hdr("Content-Type", "application/x-www-form-urlencoded");

    assert(c.post("/login", "user=ana&password=p%40ss+word", ct).body == "ana:p@ss word:-");
    assert(c.post("/login", "user=ana&password=x&note=hello", hdr("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")).body
        == "ana:x:hello");

    // validation errors say "body"
    auto r = c.post("/login", "user=a", ct);
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"string_too_short","loc":["body","user"],"msg":"expected at least 3 characters"},`
        ~ `{"type":"missing","loc":["body","password"],"msg":"Field required"}]}`, r.body);

    // any other content type: 415 with a detail
    r = c.post("/login", `{"user":"ana"}`, hdr("Content-Type", "application/json"));
    assert(r.status == 415 && r.body == `{"detail":"expected Content-Type: application/x-www-form-urlencoded"}`, r.body);
    assert(c.post("/login", "user=ana&password=x").status == 415, "no Content-Type at all");
    assert(c.post("/login", "user=ana", hdr("Content-Type", "application/x-www-form-urlencodedX")).status == 415);
}

@system unittest
{
    auto c = TestClient(build());
    auto doc = parseJSON(c.get("/openapi.json").body);
    auto params = doc["paths"]["/list"]["get"]["parameters"].array;
    string[string] required;
    foreach (p; params)
        required[p["name"].str] = p["required"].boolean ? "yes" : "no";
    assert(required == ["q": "yes", "page_size": "no", "sort": "no", "tag": "no", "exact": "no"], required.to!string);
    auto body_ = doc["paths"]["/login"]["post"]["requestBody"]["content"];
    assert("application/x-www-form-urlencoded" in body_.object);
    assert(body_["application/x-www-form-urlencoded"]["schema"]["$ref"].str == "#/components/schemas/Login");
}
