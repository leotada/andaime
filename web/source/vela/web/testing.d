/// In-memory client: exercises App + handlers without sockets.
module vela.web.testing;

@safe:

import vela.http.types;
import vela.http.response;
import vela.http.buffer : ByteBuffer;
import vela.http.websocket;
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

/// What a test client sends on a WebSocket, in order: `WsScript().text("hi").ping().close()`. Frames are masked, as a
/// real client's are. Once the script is used up the connection reports end of input (the server sees 1006 unless the
/// script ended with `close`).
struct WsScript
{
    ubyte[] bytes;

    ref WsScript text(string s, bool fin = true) return => frame(WsOpcode.text, cast(const(ubyte)[]) s, fin);
    ref WsScript binary(const(ubyte)[] b, bool fin = true) return => frame(WsOpcode.binary, b, fin);
    /// The next fragment of a message started with `text(..., false)` or `binary(..., false)`.
    ref WsScript continuation(string s, bool fin = true) return => frame(WsOpcode.continuation, cast(const(ubyte)[]) s, fin);
    ref WsScript ping(string payload = null) return => frame(WsOpcode.ping, cast(const(ubyte)[]) payload, true);

    ref WsScript close(ushort code = WsCloseCode.normal, string reason = null) return
    {
        ubyte[] p = [cast(ubyte)(code >> 8), cast(ubyte)(code & 0xFF)];
        return frame(WsOpcode.close, p ~ cast(const(ubyte)[]) reason, true);
    }

    /// Bytes exactly as given (an unmasked or malformed frame, to test the server's checks).
    ref WsScript raw(const(ubyte)[] b) return
    {
        bytes ~= b;
        return this;
    }

    ref WsScript frame(ubyte opcode, const(ubyte)[] payload, bool fin) return
    {
        static immutable ubyte[4] key = [0x12, 0x34, 0x56, 0x78];
        ByteBuffer b;
        encodeFrame(b, opcode, fin, false, payload, key[]);
        bytes ~= cast(const(ubyte)[]) b.data;
        return this;
    }
}

/// A message the server sent on a WebSocket, as the test client received it.
struct TestWsMessage
{
    WsKind kind;
    string data;

    bool isText() const => kind == WsKind.text;
    bool isBinary() const => kind == WsKind.binary;
}

/// The outcome of `TestClient.websocket`.
struct TestWsResponse
{
    /// The HTTP answer: 101 and its headers when the server upgraded, the refusal (403, 426...) otherwise.
    TestResponse response;
    /// The server's text and binary messages, in order.
    TestWsMessage[] messages;
    /// The payloads of the server's pongs.
    string[] pongs;
    /// The code of the server's close frame (0: it sent none), and its reason.
    ushort closeCode;
    string closeReason;

    int status() const => response.status;
    /// The texts of `messages`, for short assertions: `assert(r.texts == ["hi"])`.
    string[] texts() const
    {
        string[] t;
        foreach (m; messages)
            t ~= m.data;
        return t;
    }
}

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

    /// Opens a WebSocket on `target` (the upgrade headers are added for you), plays `script` to the server, and returns
    /// what came back. The handler runs to completion inside the call.
    TestWsResponse websocket(string target, WsScript script, HeaderField[] headers...)
    {
        HeaderField[] all = [hdr("Upgrade", "websocket"), hdr("Connection", "Upgrade"),
            hdr("Sec-WebSocket-Version", "13"), hdr("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")];
        sink.upgradeInput = script.bytes;
        sink.upgradeOutput.clear();
        TestWsResponse r;
        r.response = send(Method.GET, target, null, all ~ headers);
        decodeServerFrames(cast(const(ubyte)[]) sink.upgradeOutput.data, r);
        return r;
    }

    /// A WebSocket that sends nothing (its input ends at once). An overload, not a default argument: DMD 2.109 crashes on
    /// a default before a variadic parameter.
    TestWsResponse websocket(string target, HeaderField[] headers...) => websocket(target, WsScript.init, headers);

    /// The permessage-deflate factory a WebSocket route with `compression` uses (the server sets zlib's); null: none.
    WsDeflateFactory deflate;

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
        ctx.newDeflate = deflate;
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

    // ---- WebSocket: what the client sends, and what the server wrote after the 101
    const(ubyte)[] upgradeInput;
    ByteBuffer upgradeOutput;

    override UpgradedConn upgrade(ref const ResponseHead head, scope const(char)[] protocol)
    {
        start(head);
        auto c = new ScriptedConn(upgradeInput, &upgradeOutput);
        upgradeInput = null;
        return c;
    }
}

/// An upgraded connection in memory: the whole script is buffered at once, then the input ends.
private final class ScriptedConn : UpgradedConn
{
    private const(ubyte)[] input;
    private ByteBuffer* output;
    private bool closed;

    this(const(ubyte)[] input, ByteBuffer* output)
    {
        this.input = input;
        this.output = output;
        output.clear();
    }

    override const(ubyte)[] buffered() => closed ? null : input;

    override FillResult fill(int timeoutMs) => FillResult.eof;

    override void consume(size_t n)
    {
        input = input[n .. $];
    }

    override void write(scope const(ubyte)[] data)
    {
        if (closed)
            throw new WsClosed;
        output.put(cast(const(char)[]) data);
    }

    override void close()
    {
        closed = true;
    }
}

/// Splits what the server wrote into messages, pongs and its close frame.
private void decodeServerFrames(const(ubyte)[] b, ref TestWsResponse r)
{
    string partial;
    WsKind partialKind;
    while (b.length)
    {
        FrameHeader h;
        if (parseFrameHeader(b, h) != FrameParse.ok || h.masked || b.length < h.headerLength + h.length)
            throw new Exception("TestClient: the server wrote a malformed WebSocket frame");
        auto payload = cast(string) b[h.headerLength .. h.headerLength + cast(size_t) h.length].idup;
        b = b[h.headerLength + cast(size_t) h.length .. $];
        switch (h.opcode)
        {
            case WsOpcode.text:
            case WsOpcode.binary:
                partialKind = h.opcode == WsOpcode.text ? WsKind.text : WsKind.binary;
                partial = payload;
                break;
            case WsOpcode.continuation:
                partial ~= payload;
                break;
            case WsOpcode.pong:
                r.pongs ~= payload;
                continue;
            case WsOpcode.close:
                r.closeCode = payload.length >= 2 ? cast(ushort)((payload[0] << 8) | payload[1]) : WsCloseCode.noStatus;
                r.closeReason = payload.length > 2 ? payload[2 .. $] : null;
                continue;
            default: // ping
                continue;
        }
        if (h.fin)
            r.messages ~= TestWsMessage(partialKind, partial);
    }
}
