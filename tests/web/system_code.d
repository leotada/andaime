/// User code may be @system (C calls, raw pointers) without ceremony; @safe code stays checked.
module system_code;

// NOTE: no `@safe:` here on purpose. These are plain (@system) functions.

import vela;
import vela.web.testing;
import core.stdc.stdlib : getenv;
import core.stdc.string : strlen;

string fromC()
{
    auto p = getenv("PATH"); // a @system C call straight in the handler
    return p is null ? "none" : "has-path:" ~ (p[0 .. strlen(p)].length > 0 ? "yes" : "no");
}

void sysMiddleware(Context ctx, Next next)
{
    auto p = getenv("PATH");
    ctx.setHeader("X-Sys", p is null ? "0" : "1");
    next();
}

// A @safe handler in the same app is still compiled as @safe.
string safeOne() @safe => "safe";

unittest
{
    auto app = new App;
    app.use(&sysMiddleware);
    app.use((Context ctx, Next next) { auto p = getenv("PATH"); next(); }); // @system lambda
    app.onNotFound((Context ctx) { auto p = getenv("PATH"); ctx.text("gone", 404); });
    app.onError((Context ctx, Exception e) { auto p = getenv("PATH"); ctx.text("oops", 500); });
    app.get!("/c", fromC);
    app.get!("/s", safeOne);
    app.get!("/boom", () { throw new Exception("x"); return "never"; });

    auto c = TestClient(app);
    auto r = c.get("/c");
    assert(r.status == 200 && r.body == "has-path:yes", r.body);
    assert(c.get("/s").body == "safe");
    assert(c.get("/nope").body == "gone");
    assert(c.get("/boom").body == "oops");
    assert(c.get("/c").header("X-Sys") == "1");
}
