/// Streamed responses through TestClient: chunks in order, Server-Sent Events formatting, the lazy commit (an error before
/// the first write is an ordinary error response, after it the response is aborted), headers locked after the commit,
/// HEAD, status control and the OpenAPI description.
module stream_test;

@safe:

import vela;
import vela.web.testing;
import std.algorithm : canFind;
import std.json : parseJSON;

Stream csv()
{
    return Stream("text/csv", (scope StreamWriter w) @system {
        w.write("a,b\n");
        w.write("1,2\n");
        w.write("3,4\n");
    });
}

EventStream events()
{
    return EventStream((scope EventWriter w) @system {
        w.send("hello");
        w.send("line one\nline two", "update", "7");
        w.comment("keep-alive");
        w.retry(1500);
    });
}

EventStream badEvent()
{
    return EventStream((scope EventWriter w) @system {
        w.send("fine");
        w.send("x", "evil\r\nevent: injected");
    });
}

Stream failsFirst()
{
    return Stream("text/plain", (scope StreamWriter w) @system { throw new HttpError(409, "not now"); });
}

Stream failsLater()
{
    return Stream("text/plain", (scope StreamWriter w) @system {
        w.write("partial");
        throw new Exception("the database went away");
    });
}

Stream emptyStream() => Stream("text/plain", (scope StreamWriter w) @system { });

Stream headerAfter(Context ctx)
{
    ctx.setHeader("X-Before", "yes");
    return Stream("text/plain", (scope StreamWriter w) @system {
        w.write("x");
        ctx.setHeader("X-After", "no");   // too late: the head is on the wire
        ctx.addHeader("Set-Cookie", "a=b");
        w.write("y");
    });
}

WithStatus!Stream created() => withStatus(201, Stream("text/plain", (scope StreamWriter w) @system { w.write("made"); }));

@status(202) Stream accepted() => Stream("text/plain", (scope StreamWriter w) @system { w.write("queued"); });

@produces("text/csv") Stream exported() => Stream("text/csv", (scope StreamWriter w) @system { w.write("x\n"); });

string plain() => "plain";

App build(ref string[] trace)
{
    auto app = new App;
    app.use((Context c, Next n) {
        trace ~= "mw>";
        n();
        trace ~= c.committed ? "<mw committed" : "<mw";
    });
    app.get!("/csv", csv);
    app.get!("/events", events);
    app.get!("/bad-event", badEvent);
    app.get!("/fails-first", failsFirst);
    app.get!("/fails-later", failsLater);
    app.get!("/empty", emptyStream);
    app.get!("/header-after", headerAfter);
    app.get!("/created", created);
    app.get!("/accepted", accepted);
    app.get!("/exported", exported);
    app.get!("/plain", plain);
    app.serveOpenApi(OpenApiInfo("S", "1"));
    return app;
}

unittest
{
    string[] trace;
    auto c = TestClient(build(trace));

    // chunks arrive in the order they were written, one per write
    auto r = c.get("/csv");
    assert(r.status == 200 && r.contentType == "text/csv");
    assert(r.chunks == ["a,b\n", "1,2\n", "3,4\n"] && r.body == "a,b\n1,2\n3,4\n");
    assert(r.date.length > 0, "Date is added to every response");
    assert(r.header("Content-Length") is null, "a streamed response has no Content-Length");
    assert(trace == ["mw>", "<mw committed"], "the stream ran inside the middleware chain");

    // an ordinary response has a single chunk
    r = c.get("/plain");
    assert(r.chunks == ["plain"] && r.body == "plain");

    // HEAD: the head only, the body is not produced
    trace = null;
    r = c.head("/csv");
    assert(r.status == 200 && r.body.length == 0 && r.chunks.length == 0);
    r = c.get("/empty");
    assert(r.status == 200 && r.body.length == 0, "an empty stream is a valid response");
}

unittest
{
    string[] trace;
    auto c = TestClient(build(trace));

    // Server-Sent Events
    auto r = c.get("/events");
    assert(r.status == 200 && r.contentType == "text/event-stream");
    assert(r.header("Cache-Control") == "no-cache" && r.header("X-Accel-Buffering") == "no");
    assert(r.chunks == ["data: hello\n\n", "event: update\nid: 7\ndata: line one\ndata: line two\n\n", ": keep-alive\n\n",
        "retry: 1500\n\n"], r.chunks.to!string);

    // an event name with CR/LF would inject fields: the stream is aborted after the events already sent
    r = c.get("/bad-event");
    assert(r.chunks == ["data: fine\n\n"] && r.aborted, "an injected field must not reach the client");
}

version (unittest) import std.conv : to;

unittest
{
    string[] trace;
    auto c = TestClient(build(trace));

    // an error before the first write is a normal error response (the head was not committed yet)
    auto r = c.get("/fails-first");
    assert(r.status == 409 && r.body == `{"detail":"not now"}` && !r.aborted, r.body);

    // an error after the first write cannot change the status: the response is aborted
    r = c.get("/fails-later");
    assert(r.status == 200 && r.chunks == ["partial"] && r.aborted);
    assert(trace[$ - 1] == "<mw committed");

    // headers set after the commit are ignored (and logged once)
    r = c.get("/header-after");
    assert(r.header("X-Before") == "yes" && r.header("X-After") is null && r.header("Set-Cookie") is null);
    assert(r.body == "xy");
}

@system unittest
{
    string[] trace;
    auto c = TestClient(build(trace));

    assert(c.get("/created").status == 201 && c.get("/created").body == "made");
    assert(c.get("/accepted").status == 202);

    auto doc = parseJSON(c.get("/openapi.json").body);
    auto csvResp = doc["paths"]["/csv"]["get"]["responses"]["200"]["content"];
    assert("application/octet-stream" in csvResp.object);
    assert("text/event-stream" in doc["paths"]["/events"]["get"]["responses"]["200"]["content"].object);
    assert("text/csv" in doc["paths"]["/exported"]["get"]["responses"]["200"]["content"].object);
    assert("201" in doc["paths"]["/accepted"]["get"]["responses"].object || "202" in doc["paths"]["/accepted"]["get"]["responses"].object);
}
