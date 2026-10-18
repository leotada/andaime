/// Cookies: `Cookie!"name"` parameters, `ctx.cookie`, `ctx.setCookie`, `ctx.deleteCookie`.
module cookies_test 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.json : parseJSON;
import std.algorithm : canFind;

string who(Cookie!"session" s) => s.value;
string theme(Optional!(Cookie!"theme") t) => t.has ? t.get.value : "light";
string raw(Context ctx) => ctx.cookie("a") is null ? "null" : "[" ~ ctx.cookie("a").idup ~ "]";

string login(Context ctx)
{
    ctx.setCookie("session", "tok123");
    ctx.setCookie("theme", "dark", CookieOptions("/app", "example.com", Optional!long(3600), Optional!long.init, false, false, SameSite.strict));
    return "ok";
}

void bad(Context ctx, string kind)
{
    switch (kind)
    {
        case "name": ctx.setCookie("bad name", "v"); break;
        case "value": ctx.setCookie("n", "a b"); break;
        case "semi": ctx.setCookie("n", "a;b"); break;
        case "path": ctx.setCookie("n", "v", CookieOptions("/a;Secure")); break;
        case "none": ctx.setCookie("n", "v", CookieOptions("/", null, Optional!long.init, Optional!long.init, false, true, SameSite.none)); break;
        default: break;
    }
}

void logout(Context ctx)
{
    ctx.deleteCookie("session");
    ctx.setCookie("old", "x", CookieOptions("/", null, Optional!long.init, Optional!long(1_700_000_000)));
}

App build()
{
    auto app = new App;
    app.get!("/who", who);
    app.get!("/theme", theme);
    app.get!("/raw", raw);
    app.get!("/login", login);
    app.get!("/bad/{kind}", bad);
    app.get!("/logout", logout);
    app.serveOpenApi(OpenApiInfo("C", "1"));
    return app;
}

unittest
{
    auto c = TestClient(build());

    // reading
    assert(c.get("/who", hdr("Cookie", "theme=dark; session=abc; other=1")).body == "abc");
    assert(c.get("/who", hdr("Cookie", "session=abc")).body == "abc");
    auto r = c.get("/who");
    assert(r.status == 422 && r.body == `{"detail":[{"type":"missing","loc":["cookie","session"],"msg":"Field required"}]}`, r.body);
    assert(c.get("/theme").body == "light");
    assert(c.get("/theme", hdr("Cookie", "theme=dark")).body == "dark");

    // HTTP/2 may send several cookie fields; all are read. Quotes go, empty is not absent, names are exact
    assert(c.get("/who", hdr("Cookie", "x=1"), hdr("Cookie", "session=second")).body == "second");
    assert(c.get("/raw", hdr("Cookie", `a="quoted"`)).body == "[quoted]");
    assert(c.get("/raw", hdr("Cookie", "a=")).body == "[]");
    assert(c.get("/raw", hdr("Cookie", "aa=1; b=2")).body == "null", "a prefix is not a match");
    assert(c.get("/raw", hdr("Cookie", "  a = spaced ;b=2")).body == "[spaced]");
    assert(c.get("/raw").body == "null");
}

unittest
{
    auto c = TestClient(build());

    // two cookies in one response, with the safe defaults and with everything spelled out
    auto r = c.get("/login");
    assert(r.status == 200);
    assert(r.headers("Set-Cookie") == ["session=tok123; Path=/; Secure; HttpOnly; SameSite=Lax",
        "theme=dark; Path=/app; Domain=example.com; Max-Age=3600; SameSite=Strict"], r.headers("Set-Cookie").to!string);

    // deleting, and an absolute expiry
    r = c.get("/logout");
    assert(r.headers("Set-Cookie") == ["session=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=Lax",
        "old=x; Path=/; Expires=Tue, 14 Nov 2023 22:13:20 GMT; Secure; HttpOnly; SameSite=Lax"], r.headers("Set-Cookie").to!string);

    // programming errors are a 500, never a malformed header
    foreach (kind; ["name", "value", "semi", "path", "none"])
    {
        r = c.get("/bad/" ~ kind);
        assert(r.status == 500 && r.header("Set-Cookie") is null, kind);
    }
    assert(c.get("/bad/fine").status == 204);
}

version (unittest) import std.conv : to;

@system unittest
{
    auto c = TestClient(build());
    auto doc = parseJSON(c.get("/openapi.json").body);
    auto p = doc["paths"]["/who"]["get"]["parameters"].array[0];
    assert(p["name"].str == "session" && p["in"].str == "cookie" && p["required"].boolean);
    auto t = doc["paths"]["/theme"]["get"]["parameters"].array[0];
    assert(t["in"].str == "cookie" && !t["required"].boolean);
}
