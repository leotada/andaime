/// Text types (`fromString` + `toString`): a Uuid and an ISO date travel through path, query, header, JSON and OpenAPI.
module text_types 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.json : parseJSON;

struct Uuid
{
    ubyte[16] bytes;

    static bool fromString(scope const(char)[] t, out Uuid v)
    {
        if (t.length != 36)
            return false;
        size_t o;
        for (size_t i = 0; i < 36; i++)
        {
            if (i == 8 || i == 13 || i == 18 || i == 23)
            {
                if (t[i] != '-')
                    return false;
                continue;
            }
            immutable int d = t[i] >= '0' && t[i] <= '9' ? t[i] - '0' : (t[i] >= 'a' && t[i] <= 'f' ? t[i] - 'a' + 10
                : (t[i] >= 'A' && t[i] <= 'F' ? t[i] - 'A' + 10 : -1));
            if (d < 0)
                return false;
            if (o % 2 == 0) v.bytes[o / 2] = cast(ubyte)(d << 4); else v.bytes[o / 2] |= cast(ubyte) d;
            o++;
        }
        return true;
    }

    void toString(scope void delegate(scope const(char)[]) @safe sink) const
    {
        static immutable hex = "0123456789abcdef";
        char[36] t;
        size_t k;
        foreach (i, b; bytes)
        {
            if (i == 4 || i == 6 || i == 8 || i == 10)
                t[k++] = '-';
            t[k++] = hex[b >> 4];
            t[k++] = hex[b & 15];
        }
        sink(t[]);
    }

    enum openApiFormat = "uuid";
    enum invalidMessage = "expected a UUID like 123e4567-e89b-12d3-a456-426614174000";
}

/// A date as year/month/day: no format string, just a different shape and the default message.
struct Day
{
    int y, m, d;

    static bool fromString(scope const(char)[] t, out Day v)
    {
        if (t.length != 10 || t[4] != '-' || t[7] != '-')
            return false;
        int num(size_t from, size_t to)
        {
            int r;
            foreach (c; t[from .. to])
            {
                if (c < '0' || c > '9')
                    return -1;
                r = r * 10 + (c - '0');
            }
            return r;
        }
        v.y = num(0, 4);
        v.m = num(5, 7);
        v.d = num(8, 10);
        return v.y >= 0 && v.m >= 1 && v.m <= 12 && v.d >= 1 && v.d <= 31;
    }

    void toString(scope void delegate(scope const(char)[]) @safe sink) const
    {
        char[10] t;
        t[0] = cast(char)('0' + y / 1000 % 10); t[1] = cast(char)('0' + y / 100 % 10);
        t[2] = cast(char)('0' + y / 10 % 10); t[3] = cast(char)('0' + y % 10); t[4] = '-';
        t[5] = cast(char)('0' + m / 10); t[6] = cast(char)('0' + m % 10); t[7] = '-';
        t[8] = cast(char)('0' + d / 10); t[9] = cast(char)('0' + d % 10);
        sink(t[]);
    }
}

/// The text of a text type, as a string (tests only: the framework itself never allocates for this).
string text(T)(const T v)
{
    string r;
    v.toString((scope const(char)[] piece) { r ~= piece; });
    return r;
}

struct Order { Uuid id; Day placed; Optional!Uuid parent; string note; }

string fromPath(Uuid id) => text(id);
string fromQuery(Day since, Optional!Uuid owner) => text(since) ~ "/" ~ (owner.has ? text(owner.get) : "none");
Order echo(JsonBody!Order o) => o.value;

App build()
{
    auto app = new App;
    app.get!("/u/{id}", fromPath);
    app.get!("/q", fromQuery);
    app.post!("/order", echo);
    app.serveOpenApi(OpenApiInfo("T", "1"));
    return app;
}

enum good = "123e4567-e89b-12d3-a456-426614174000";

unittest
{
    auto c = TestClient(build());
    assert(c.get("/u/" ~ good).body == good);
    assert(c.get("/u/123E4567-E89B-12D3-A456-426614174000").body == good, "parsed case-insensitively, written in lower case");

    // query, with an Optional text type
    assert(c.get("/q?since=2024-03-05").body == "2024-03-05/none");
    assert(c.get("/q?since=2024-03-05&owner=" ~ good).body == "2024-03-05/" ~ good);

    // JSON in and out: a text type is a string
    auto r = c.post("/order", `{"id":"` ~ good ~ `","placed":"2025-12-31","note":"hi \"there\""}`);
    assert(r.status == 200);
    assert(r.body == `{"id":"` ~ good ~ `","placed":"2025-12-31","parent":null,"note":"hi \"there\""}`, r.body);
    r = c.post("/order", `{"id":"` ~ good ~ `","placed":"2025-01-02","parent":"` ~ good ~ `","note":""}`);
    assert(r.status == 200 && r.body.length > 0);
}

unittest
{
    auto c = TestClient(build());

    // fromString says no: value_error, with the type's own message or the default one
    auto r = c.get("/u/not-a-uuid");
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"value_error","loc":["path","id"],"msg":"expected a UUID like 123e4567-e89b-12d3-a456-426614174000"}]}`, r.body);
    r = c.get("/q?since=yesterday");
    assert(r.body == `{"detail":[{"type":"value_error","loc":["query","since"],"msg":"invalid Day"}]}`, r.body);

    // in JSON: wrong kind, and invalid text, with the path of the field
    r = c.post("/order", `{"id":5,"placed":"2025-13-40","note":"x"}`);
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"string_type","loc":["body","id"],"msg":"expected a string"},`
        ~ `{"type":"value_error","loc":["body","placed"],"msg":"invalid Day"}]}`, r.body);
}

@system unittest
{
    auto c = TestClient(build());
    auto doc = parseJSON(c.get("/openapi.json").body);
    auto p = doc["paths"]["/u/{id}"]["get"]["parameters"].array[0];
    assert(p["schema"]["type"].str == "string" && p["schema"]["format"].str == "uuid");
    auto day = doc["paths"]["/q"]["get"]["parameters"].array[0];
    assert(day["schema"]["type"].str == "string" && "format" !in day["schema"].object, "a type without openApiFormat has none");
    auto order = doc["components"]["schemas"]["Order"]["properties"];
    assert(order["id"]["format"].str == "uuid" && order["placed"]["type"].str == "string");
}
