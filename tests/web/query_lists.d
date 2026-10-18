/// Repeated query parameters as lists: `?tag=a&tag=b` -> `string[] tag`.
module query_lists 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.json : parseJSON;
import std.conv : to;

enum Sort { asc, desc }

string tags(string[] tag) => tag.length.to!string ~ ":" ~ join(tag);
string ids(int[] id, int[] other = [7, 8]) => join(id.to!(string[])) ~ "|" ~ join(other.to!(string[]));
string sorts(Sort[] by) => by.length.to!string;
string mixed(string q, string[] tag, int limit = 5) => q ~ "/" ~ tag.length.to!string ~ "/" ~ limit.to!string;

string join(const(string)[] a)
{
    string r;
    foreach (i, s; a)
        r ~= (i ? "," : "") ~ s;
    return r;
}

App build()
{
    auto app = new App;
    app.get!("/tags", tags);
    app.get!("/ids", ids);
    app.get!("/sorts", sorts);
    app.get!("/mixed", mixed);
    app.serveOpenApi(OpenApiInfo("L", "1"));
    return app;
}

unittest
{
    auto c = TestClient(build());

    assert(c.get("/tags?tag=a&tag=b%20c&tag=").body == "3:a,b c,");
    assert(c.get("/tags").body == "0:", "absent is an empty list, not an error");
    assert(c.get("/tags?tag=only").body == "1:only");
    assert(c.get("/ids?id=1&id=22&id=-3").body == "1,22,-3|7,8", "a list with a default keeps it when absent");
    assert(c.get("/ids?id=1&other=5&other=6").body == "1|5,6");
    assert(c.get("/ids").body == "|7,8");
    assert(c.get("/sorts?by=asc&by=desc&by=asc").body == "3");
    assert(c.get("/mixed?q=x&tag=a&limit=2&tag=b").body == "x/2/2", "lists and scalars coexist");

    // the error says which element
    auto r = c.get("/ids?id=1&id=nope&id=3&id=99999999999");
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"int_parsing","loc":["query","id",1],"msg":"expected an integer between -2147483648 and 2147483647"},`
        ~ `{"type":"int_parsing","loc":["query","id",3],"msg":"expected an integer between -2147483648 and 2147483647"}]}`, r.body);
    r = c.get("/sorts?by=asc&by=sideways");
    assert(r.status == 422 && r.body == `{"detail":[{"type":"enum","loc":["query","by",1],"msg":"expected one of: asc, desc"}]}`, r.body);
    r = c.get("/tags?tag=ok&tag=%FF");
    assert(r.status == 422 && r.body == `{"detail":[{"type":"string_unicode","loc":["query","tag",1],"msg":"invalid UTF-8"}]}`, r.body);
}

@system unittest
{
    auto c = TestClient(build());
    auto doc = parseJSON(c.get("/openapi.json").body);
    foreach (p; doc["paths"]["/tags"]["get"]["parameters"].array)
    {
        assert(p["name"].str == "tag" && p["in"].str == "query" && !p["required"].boolean);
        assert(p["schema"]["type"].str == "array" && p["schema"]["items"]["type"].str == "string");
        assert(p["style"].str == "form" && p["explode"].boolean);
    }
    assert(doc["paths"]["/ids"]["get"]["parameters"].array[0]["schema"]["items"]["format"].str == "int32");
}
