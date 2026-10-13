/// In-memory client: exercises App + handlers without sockets.
module vela.web.testing;

@safe:

import vela.http.types;
import vela.http.response;
import vela.http.ip : IpAddress, parseIp;
import vela.web.context;
import vela.web.application;
import vela.web.stream : sendResponse;

struct TestResponse
{
    int status;
    string contentType;
    string body;
    HeaderField[] headerList; /// every header, in order; `header(name)` and `headers(name)` look them up
    /// The pieces of the body as the sink received them: a streamed response has one per `write` (a Server-Sent Event,
    /// say); an ordinary one has a single chunk. `body` is their concatenation.
    string[] chunks;
    /// The announced body length (`Content-Length`), -1 when the length was not known up front (a stream).
    long contentLength = -1;
    /// A streamed response failed after it started (a real client would see a truncated body).
    bool aborted;

    /// The `Date` header, which the server adds to every response.
    string date() const => header("Date");

    string header(string name) const
    {
        foreach (h; headerList)
            if (equalsIgnoreCase(h.name, name))
                return h.value.idup;
        return null;
    }

    /// Every value of the header, in order (several `Set-Cookie`).
    string[] headers(string name) const
    {
        string[] r;
        foreach (h; headerList)
            if (equalsIgnoreCase(h.name, name))
                r ~= h.value.idup;
        return r;
    }
}

HeaderField hdr(string name, string value) => HeaderField(name, value);

struct TestClient
{
    private App app;
    private Context ctx;
    private RecordingSink sink;
    /// The TCP peer the requests come from (default 127.0.0.1:50000). Change it with `from`.
    IpAddress peer = IpAddress.fromNetworkOrderV4(0x0100007f, 50_000);

    /// Sends the following requests from this address: `c.from("10.0.0.5").get("/x")`.
    ref TestClient from(string address) return
    {
        IpAddress a;
        if (!parseIp(address, a))
            throw new Exception("TestClient.from: not an IP address: " ~ address);
        peer = a;
        return this;
    }

    this(App app)
    {
        this.app = app;
        ctx = new Context;
        sink = new RecordingSink;
    }

    TestResponse get(string target, HeaderField[] headers...) => send(Method.GET, target, null, headers);
    TestResponse post(string target, string body, HeaderField[] headers...) => send(Method.POST, target, body, headers);
    TestResponse put(string target, string body, HeaderField[] headers...) => send(Method.PUT, target, body, headers);
    TestResponse patch(string target, string body, HeaderField[] headers...) => send(Method.PATCH, target, body, headers);
    TestResponse del(string target, HeaderField[] headers...) => send(Method.DELETE, target, null, headers);
    TestResponse head(string target, HeaderField[] headers...) => send(Method.HEAD, target, null, headers);
    TestResponse options(string target, HeaderField[] headers...) => send(Method.OPTIONS, target, null, headers);

    /// Any method: `request(Method.GET, "/x", null, hdr("Accept", "text/csv"))`.
    TestResponse request(Method m, string target, string body = null, HeaderField[] headers...)
        => send(m, target, body, headers);

    TestResponse send(Method m, string target, string body, HeaderField[] headers)
    {
        sink.reset(m);
        Request req;
        req.method = m;
        req.target = target;
        splitTarget(target, req.path, req.query);
        req.headers = headers.dup;
        req.body = cast(const(ubyte)[]) body;
        req.peer = peer;
        ctx.reset(req, sink);
        app.handle(ctx);
        try
            sendResponse(ctx); // the same finishing step as the server's: Date, no body for HEAD/204/304
        catch (ResponseAborted)
            sink.aborted = true;
        ctx.sink = null;

        TestResponse r;
        r.status = sink.status;
        r.contentType = sink.contentType;
        r.headerList = sink.headerList;
        r.chunks = sink.chunks;
        foreach (c; sink.chunks)
            r.body ~= c;
        r.aborted = sink.aborted;
        r.contentLength = sink.contentLength;
        return r;
    }
}

/// What a client would see, recorded: status, headers and the body in the pieces it was written in.
private final class RecordingSink : ResponseSink
{
    int status;
    string contentType;
    long contentLength = -1;
    HeaderField[] headerList;
    string[] chunks;
    bool aborted;
    private bool noBody;
    private Method method;

    void reset(Method m)
    {
        method = m;
        status = 0;
        contentLength = -1;
        contentType = null;
        headerList = null;
        chunks = null;
        aborted = false;
        noBody = false;
    }

    override void start(ref const ResponseHead head)
    {
        status = head.status;
        contentLength = head.contentLength;
        contentType = head.contentType.idup;
        foreach (ref h; head.headers)
            headerList ~= HeaderField(h.name.idup, h.value.idup);
        noBody = method == Method.HEAD || statusHasNoBody(head.status);
    }

    override void write(scope const(char)[] data)
    {
        if (!noBody && data.length)
            chunks ~= data.idup;
    }

    override void flush()
    {
    }

    override void end()
    {
    }
}
