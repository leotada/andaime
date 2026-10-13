/// Response headers: validation (response splitting), several values, replace vs add, Vary merging, the 32-header
/// limit and the headers vela owns.
module headers;

@safe:

import vela;
import vela.web.testing;

Response redirect(string to) => Response.redirect(to);

Response cookies()
{
    return Response(200, "text/plain; charset=utf-8", "ok",
        [HeaderField("Set-Cookie", "a=1; Path=/"), HeaderField("Set-Cookie", "b=2; Path=/")]);
}

Response nulValue() => Response(200, "text/plain", "x", [HeaderField("X-Bad", "a\0b")]);
Response badName() => Response(200, "text/plain", "x", [HeaderField("Bad Name", "v")]);
Response badType() => Response(200, "text/plain\r\nX-Evil: 1", "x");

Response owned()
{
    return Response(200, "text/plain", "hello", [HeaderField("Content-Length", "999"),
        HeaderField("Connection", "upgrade"), HeaderField("Transfer-Encoding", "chunked"),
        HeaderField("X-Keep", "yes")]);
}

string many(Context ctx)
{
    foreach (i; 0 .. 33)
        ctx.addHeader("X-N", "v");
    return "x";
}

string exactly32(Context ctx)
{
    foreach (i; 0 .. 32)
        ctx.addHeader("X-N", "v");
    return "x";
}

string replaced(Context ctx)
{
    ctx.setHeader("X-A", "1");
    ctx.addHeader("X-A", "2");
    ctx.setHeader("x-a", "3"); // replaces both, any case
    ctx.addVary("Origin");
    ctx.addVary("Accept-Encoding");
    ctx.addVary("origin"); // duplicate, other case
    return "x";
}

App build()
{
    auto app = new App;
    app.get!("/redirect", redirect);
    app.get!("/cookies", cookies);
    app.get!("/nul", nulValue);
    app.get!("/badname", badName);
    app.get!("/badtype", badType);
    app.get!("/owned", owned);
    app.get!("/many", many);
    app.get!("/exactly32", exactly32);
    app.get!("/replaced", replaced);
    return app;
}

unittest
{
    auto c = TestClient(build());

    // response splitting: CR/LF from user input never reaches the wire
    auto r = c.get("/redirect?to=/x%0d%0aSet-Cookie:%20pwned=1");
    assert(r.status == 500, "CR/LF in Location must become a 500");
    assert(r.header("Location") is null && r.header("Set-Cookie") is null);
    assert(r.body == `{"detail":"internal error"}`, r.body);

    r = c.get("/redirect?to=/ok");
    assert(r.status == 307 && r.header("Location") == "/ok");

    // NUL, an invalid name and a bad Content-Type
    assert(c.get("/nul").status == 500);
    assert(c.get("/badname").status == 500);
    assert(c.get("/badtype").status == 500);
}

unittest
{
    auto c = TestClient(build());

    // two cookies survive
    auto r = c.get("/cookies");
    assert(r.status == 200);
    assert(r.headers("Set-Cookie") == ["a=1; Path=/", "b=2; Path=/"], "both cookies must be kept");
    assert(r.header("Set-Cookie") == "a=1; Path=/");

    // setHeader replaces every value of the name, addVary merges into one header
    r = c.get("/replaced");
    assert(r.headers("X-A") == ["3"]);
    assert(r.headers("Vary") == ["Origin, Accept-Encoding"], r.headers("Vary")[0]);
}

unittest
{
    auto c = TestClient(build());

    // headers vela owns are dropped, the others stay
    auto r = c.get("/owned");
    assert(r.status == 200 && r.body == "hello");
    assert(r.header("Content-Length") is null && r.header("Connection") is null && r.header("Transfer-Encoding") is null);
    assert(r.header("X-Keep") == "yes");

    // 33 headers: a clear 500; exactly 32 is fine
    assert(c.get("/many").status == 500);
    r = c.get("/exactly32");
    assert(r.status == 200 && r.headers("X-N").length == 32);
}

unittest
{
    // the wire form: Date is added by the server only when the application did not set it
    Context ctx = new Context;
    ctx.response.ensureHeader("Date", "server");
    ctx.response.setHeader("Date", "app");
    assert(ctx.response.header("Date") == "app");
    ctx.response.reset();
    ctx.response.setHeader("Date", "app");
    ctx.response.ensureHeader("Date", "server");
    assert(ctx.response.header("Date") == "app" && ctx.response.headers.length == 1);
}
