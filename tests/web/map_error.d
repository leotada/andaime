/// `App.mapError!E(status)`: an exception type answered like `HttpError(status, msg)`, without a log line; subclasses
/// match, the first mapping wins, `onError` receives the `HttpError`, and a bad status or a late call throws.
module map_error;

@safe:

import andaime;
import andaime.web.testing;

class DomainError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe { super(msg, file, line); }
}

class NotFound : DomainError
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe { super(msg, file, line); }
}

class Conflict : DomainError
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe { super(msg, file, line); }
}

string missing() { throw new NotFound("user not found"); }
string taken() { throw new Conflict("email taken"); }
string other() { throw new DomainError("some rule"); }
string broken() { throw new Exception("kaput"); }

App buildApp()
{
    auto app = new App;
    app.mapError!NotFound(404);
    app.mapError!DomainError(422); // after NotFound: the first match wins, so NotFound stays 404
    app.get!("/missing", missing);
    app.get!("/taken", taken);
    app.get!("/other", other);
    app.get!("/broken", broken);
    return app;
}

unittest // mapped types answer their status with {"detail": msg} and log nothing; others are still 500 and logged
{
    auto c = TestClient(buildApp());
    TestResponse r;
    auto logs = captureLog({ r = c.get("/missing"); });
    assert(r.status == 404 && r.body == `{"detail":"user not found"}`, r.body);
    assert(logs.length == 0);

    logs = captureLog({ r = c.get("/taken"); }); // a subclass of DomainError, mapped through it
    assert(r.status == 422 && r.body == `{"detail":"email taken"}`, r.body);
    assert(logs.length == 0);

    assert(c.get("/other").status == 422);

    logs = captureLog({ r = c.get("/broken"); });
    assert(r.status == 500 && r.body == `{"detail":"internal error"}`);
    assert(logs.length == 1 && logs[0].message == "error in handler");
}

unittest // onError receives the HttpError a mapping made, and is not preceded by a log line
{
    auto app = buildApp();
    int seen;
    app.onError((Context ctx, Exception e) {
        auto he = cast(HttpError) e;
        assert(he !is null && he.status == 404 && he.msg == "user not found");
        seen++;
        ctx.text("custom " ~ he.msg, he.status);
    });
    auto c = TestClient(app);
    TestResponse r;
    auto logs = captureLog({ r = c.get("/missing"); });
    assert(r.status == 404 && r.body == "custom user not found" && seen == 1, r.body);
    assert(logs.length == 0);
}

unittest // a status that is not an error, or a mapping after the app froze, throws RouteError
{
    auto app = new App;
    foreach (bad; [200, 399, 600])
    {
        bool threw;
        try
            app.mapError!NotFound(bad);
        catch (RouteError e)
            threw = e.msg.length > 25 && e.msg[0 .. 25] == "andaime: mapError!NotFoun";
        assert(threw);
    }
    auto c = TestClient(app);
    c.get("/");
    bool late;
    try
        app.mapError!NotFound(404);
    catch (RouteError)
        late = true;
    assert(late);
}
