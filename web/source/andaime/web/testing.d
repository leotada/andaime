/// In-memory client: exercises App + handlers without sockets.
module andaime.web.testing 2025;

@safe:

import andaime.http.types;
import andaime.http.response;
import andaime.http.buffer : ByteBuffer;
import andaime.http.websocket;
import andaime.http.ip : IpAddress, parseIp;
import andaime.log : LogLevel, LogRecord, setThreadLogSink;
import andaime.web.context;
import andaime.web.application;
import andaime.web.stream : sendResponse;
import andaime.web.jsonvalue : JsonValue;

/// One log line collected by `captureLog`: the parts of a `LogRecord`, copied.
struct CapturedLog
{
    LogLevel level;
    string message;
    string requestId; /// empty outside a request
    string line;      /// as it would have been written, newline included
    string[2][] fields; /// (key, value) pairs in order; see `LogField` for how values are written

    /// The value of the field `key`, or null when the line has none.
    string field(string key) const
    {
        foreach (ref f; fields)
            if (f[0] == key)
                return f[1];
        return null;
    }

    /// Whether the line has a field `key`.
    bool has(string key) const
    {
        foreach (ref f; fields)
            if (f[0] == key)
                return true;
        return false;
    }
}

/// Runs `dg` and returns the lines it logged (with `andaime.log`) on this thread instead of writing them to stderr, in
/// order. The level and format in force apply (`configureLog`): a line below the level is not collected.
///
///     auto logs = captureLog({ c.get("/boom"); });
///     assert(logs[0].level == LogLevel.error && logs[0].field("path") == "/boom");
///
/// Only the calling thread is captured, which is every `TestClient` request; a real server's workers have their own
/// threads (use `setLogSink` there).
CapturedLog[] captureLog(scope void delegate() @safe dg)
{
    CapturedLog[] got;
    auto prev = setThreadLogSink((scope ref const LogRecord r) @safe {
        CapturedLog c;
        c.level = r.level;
        c.message = r.message.idup;
        c.requestId = r.requestId.idup;
        c.line = r.line.idup;
        foreach (ref f; r.fields)
            c.fields ~= [f.key.idup, f.value.idup];
        got ~= c;
    });
    scope (exit)
        setThreadLogSink(prev);
    dg();
    return got;
}

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

    /// The body decoded into `T` with the rules of a request body (`fromJson`); throws `JsonError` when it does not fit:
    /// `auto user = c.get("/users/1").json!User;`.
    T json(T)() const
    {
        import andaime.web.jsonvalue : fromJson;

        return fromJson!T(body);
    }

    /// The body as a `JsonValue`; throws `JsonError` when it is not JSON: `assert(r.json["items"].length == 2);`.
    JsonValue json()() const
    {
        import andaime.web.jsonvalue : parseJson;

        return parseJson(body);
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
    /// The HTTP answer: 101 (200 over HTTP/2) and its headers when the server upgraded, the refusal (403, 426...)
    /// otherwise.
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

/// A body handed over in pieces, as the engine does for a large one (see `TestClient.bufferBodyBytes`).
private final class PieceReader : BodyReader
{
    private const(ubyte)[] rest;
    private size_t piece;

    this(const(ubyte)[] body, size_t piece)
    {
        rest = body;
        this.piece = piece ? piece : 1;
    }

    override size_t read(scope ubyte[] into)
    {
        size_t n = into.length < piece ? into.length : piece;
        if (n > rest.length)
            n = rest.length;
        into[0 .. n] = rest[0 .. n];
        rest = rest[n .. $];
        return n;
    }

    override ulong unread() const => rest.length;
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
    TestResponse request(Method m, string target, string body, HeaderField[] headers...)
        => send(m, target, body, headers);
    /// ditto, with no body and no headers. (An overload, not a default for `body`: DMD 2.109 crashes on a call that
    /// relies on a default argument placed before a variadic parameter.)
    TestResponse request(Method m, string target) => send(m, target, null, null);

    /// Sends `value` as JSON (`Content-Type: application/json`): a DTO, an array, a `JsonValue`... or JSON text as is.
    TestResponse postJson(T)(string target, auto ref T value, HeaderField[] headers...)
        => sendJson(Method.POST, target, value, headers);
    /// ditto
    TestResponse putJson(T)(string target, auto ref T value, HeaderField[] headers...)
        => sendJson(Method.PUT, target, value, headers);
    /// ditto
    TestResponse patchJson(T)(string target, auto ref T value, HeaderField[] headers...)
        => sendJson(Method.PATCH, target, value, headers);

    private TestResponse sendJson(T)(Method m, string target, ref T value, HeaderField[] headers)
    {
        static if (is(T : const(char)[]))
            string text = value.idup;
        else
        {
            import andaime.web.jsonvalue : toJson;

            string text = toJson(value);
        }
        return send(m, target, text, [hdr("Content-Type", "application/json")] ~ headers);
    }

    /// Sends a `multipart/form-data` body built from text `fields` (name, value) and `files`, as a browser form would:
    /// `c.postMultipart("/upload", [["title", "Trip"]], [TestFile("photo", "a.jpg", "image/jpeg", bytes)])`.
    TestResponse postMultipart(string target, const(string[2])[] fields, const(TestFile)[] files, HeaderField[] headers...)
        => sendMultipart(Method.POST, target, fields, files, headers);
    /// ditto, text fields only. (Overloads, not a default argument: DMD 2.109 crashes on a default before a variadic.)
    TestResponse postMultipart(string target, const(string[2])[] fields)
        => sendMultipart(Method.POST, target, fields, null, null);
    /// ditto
    TestResponse putMultipart(string target, const(string[2])[] fields, const(TestFile)[] files, HeaderField[] headers...)
        => sendMultipart(Method.PUT, target, fields, files, headers);
    /// ditto
    TestResponse putMultipart(string target, const(string[2])[] fields)
        => sendMultipart(Method.PUT, target, fields, null, null);

    private TestResponse sendMultipart(Method m, string target, const(string[2])[] fields, const(TestFile)[] files,
        scope HeaderField[] headers)
    {
        auto b = multipartBody(fields, files);
        return send(m, target, b.body, [hdr("Content-Type", "multipart/form-data; boundary=" ~ b.boundary)] ~ headers);
    }

    /// With `cookies = true` the client keeps the cookies responses set (`Set-Cookie`, honoring `Path`, `Max-Age` and
    /// `Expires`, so a deleted cookie goes away) and sends the matching ones back, like a browser. Off by default.
    bool cookies;
    private TestCookie[] jar;

    /// The value of a cookie in the jar, or null.
    string cookie(string name) const
    {
        foreach (ref c; jar)
            if (c.name == name)
                return c.value;
        return null;
    }

    /// Empties the jar.
    void clearCookies()
    {
        jar = null;
    }

    /// Opens a WebSocket on `target` (the upgrade headers are added for you), plays `script` to the server, and returns
    /// what came back. The handler runs to completion inside the call.
    /// With `http2` set, the extended CONNECT of RFC 8441 instead, answered with 200.
    TestWsResponse websocket(string target, WsScript script, HeaderField[] headers...)
    {
        HeaderField[] all = http2 ? [hdr("sec-websocket-version", "13")]
            : [hdr("Upgrade", "websocket"), hdr("Connection", "Upgrade"), hdr("Sec-WebSocket-Version", "13"),
                hdr("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")];
        sink.upgradeInput = script.bytes;
        sink.upgradeOutput.clear();
        TestWsResponse r;
        if (http2)
            connectProtocol = "websocket";
        scope (exit)
            connectProtocol = null;
        r.response = send(Method.GET, target, null, all ~ headers);
        decodeServerFrames(cast(const(ubyte)[]) sink.upgradeOutput.data, r);
        return r;
    }

    /// A WebSocket that sends nothing (its input ends at once). An overload, not a default argument: DMD 2.109 crashes on
    /// a default before a variadic parameter.
    TestWsResponse websocket(string target, HeaderField[] headers...) => websocket(target, WsScript.init, headers);

    /// The permessage-deflate factory a WebSocket route with `compression` uses (the server sets zlib's); null: none.
    WsDeflateFactory deflate;

    /// Sends the requests as HTTP/2 ones (`Request.protocol`), and `websocket` opens its WebSocket as a browser does on
    /// an HTTP/2 connection: an extended CONNECT (RFC 8441), answered with 200 instead of 101.
    bool http2;

    /// Set by `websocket` for the request it sends; see `Request.connectProtocol`.
    private string connectProtocol;

    /// Like the server's `ServerConfig.bufferBodyBytes`: an HTTP/1 body larger than this reaches the app unread, through
    /// `Request.bodyReader`, in pieces of `streamPieceBytes`, so tests go through the same path as a large upload.
    /// 0 = every body is buffered.
    size_t bufferBodyBytes = 256 << 10;
    /// ditto
    size_t streamPieceBytes = 4093;

    TestResponse send(Method m, string target, string body, scope HeaderField[] headers)
    {
        sink.reset(m);
        Request req;
        req.method = m;
        req.target = target;
        splitTarget(target, req.path, req.query);
        req.headers = cookies ? withJarCookies(req.path, headers) : headers.dup;
        if (!http2 && bufferBodyBytes && body.length > bufferBodyBytes)
            req.bodyReader = new PieceReader(cast(const(ubyte)[]) body, streamPieceBytes);
        else
            req.body = cast(const(ubyte)[]) body;
        req.peer = peer;
        req.protocol = http2 ? Protocol.http2 : Protocol.http1;
        req.connectProtocol = connectProtocol;
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
        if (cookies)
            foreach (v; r.headers("Set-Cookie"))
                storeCookie(v, req.path);
        return r;
    }

    /// The request's headers plus the jar's cookies for `path` (merged into the caller's `Cookie` header, if any).
    private HeaderField[] withJarCookies(const(char)[] path, scope HeaderField[] headers)
    {
        string jarText;
        foreach (ref c; jar)
            if (pathMatches(path, c.path))
                jarText ~= (jarText.length ? "; " : "") ~ c.name ~ "=" ~ c.value;
        auto all = headers.dup;
        if (jarText.length == 0)
            return all;
        foreach (ref h; all)
            if (equalsIgnoreCase(h.name, "Cookie"))
            {
                h.value = h.value.idup ~ "; " ~ jarText;
                return all;
            }
        return all ~ hdr("Cookie", jarText);
    }

    /// Takes one `Set-Cookie` into the jar (RFC 6265 §5.2-5.3, without domains: the test client has one host).
    private void storeCookie(string header, const(char)[] requestPath)
    {
        auto parts = splitSemicolons(header);
        if (parts.length == 0)
            return;
        auto eq = indexOfChar(parts[0], '=');
        if (eq <= 0)
            return;
        TestCookie c;
        c.name = trim(parts[0][0 .. eq]);
        c.value = trim(parts[0][eq + 1 .. $]);
        bool expired;
        bool hasMaxAge;
        foreach (attr; parts[1 .. $])
        {
            auto ae = indexOfChar(attr, '=');
            auto key = trim(ae < 0 ? attr : attr[0 .. ae]);
            auto val = ae < 0 ? "" : trim(attr[ae + 1 .. $]);
            if (equalsIgnoreCase(key, "Path") && val.length && val[0] == '/')
                c.path = val;
            else if (equalsIgnoreCase(key, "Max-Age"))
            {
                hasMaxAge = true;
                expired = val.length && (val[0] == '-' || val == "0");
            }
            else if (equalsIgnoreCase(key, "Expires") && !hasMaxAge)
                expired = httpDateInPast(val);
        }
        if (c.path is null)
            c.path = defaultPath(requestPath);
        foreach (i, ref old; jar)
            if (old.name == c.name && old.path == c.path)
            {
                if (expired)
                    jar = jar[0 .. i] ~ jar[i + 1 .. $];
                else
                    old.value = c.value;
                return;
            }
        if (!expired)
            jar ~= c;
    }
}

/// A file part for `postMultipart`.
struct TestFile
{
    string name;        /// the form field
    string filename;
    string contentType = "application/octet-stream";
    const(ubyte)[] bytes;
}

private struct TestCookie
{
    string name, value, path;
}

/// RFC 6265 §5.1.4: `path` is `cookiePath` or below it.
private bool pathMatches(scope const(char)[] path, scope const(char)[] cookiePath) pure nothrow @nogc
{
    if (path.length < cookiePath.length || path[0 .. cookiePath.length] != cookiePath)
        return false;
    return path.length == cookiePath.length || cookiePath[$ - 1] == '/' || path[cookiePath.length] == '/';
}

/// RFC 6265 §5.1.4: the directory of the request path (`/a/b` -> `/a`, `/a` -> `/`).
private string defaultPath(scope const(char)[] path) pure nothrow
{
    if (path.length == 0 || path[0] != '/')
        return "/";
    size_t last = 0;
    foreach (i, char ch; path)
        if (ch == '/')
            last = i;
    return last == 0 ? "/" : path[0 .. last].idup;
}

private string[] splitSemicolons(string s) pure nothrow
{
    string[] r;
    size_t start = 0;
    foreach (i, char ch; s)
        if (ch == ';')
        {
            r ~= s[start .. i];
            start = i + 1;
        }
    r ~= s[start .. $];
    return r;
}

private ptrdiff_t indexOfChar(scope const(char)[] s, char c) pure nothrow @nogc
{
    foreach (i, char ch; s)
        if (ch == c)
            return i;
    return -1;
}

private string trim(string s) pure nothrow @nogc
{
    while (s.length && (s[0] == ' ' || s[0] == '\t'))
        s = s[1 .. $];
    while (s.length && (s[$ - 1] == ' ' || s[$ - 1] == '\t'))
        s = s[0 .. $ - 1];
    return s;
}

/// Whether an IMF-fixdate (`Thu, 01 Jan 1970 00:00:00 GMT`, what `setCookie` writes) is in the past. An unparsable
/// date is not (the cookie is kept, as a browser would).
private bool httpDateInPast(scope const(char)[] d) nothrow @trusted
{
    // @trusted: time(null) only reads the clock
    import core.stdc.time : time;

    if (d.length != 29 || d[3] != ',' || d[$ - 4 .. $] != " GMT")
        return false;
    static int num(scope const(char)[] s) pure nothrow @nogc
    {
        int v;
        foreach (char c; s)
        {
            if (c < '0' || c > '9')
                return -1;
            v = v * 10 + (c - '0');
        }
        return v;
    }
    static immutable months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    int month = -1;
    foreach (i, mname; months)
        if (d[8 .. 11] == mname)
            month = cast(int) i + 1;
    immutable day = num(d[5 .. 7]), year = num(d[12 .. 16]);
    immutable hh = num(d[17 .. 19]), mm = num(d[20 .. 22]), ss = num(d[23 .. 25]);
    if (month < 0 || day < 0 || year < 0 || hh < 0 || mm < 0 || ss < 0)
        return false;
    // days since 1970-01-01 (H. Hinnant's days_from_civil)
    immutable y = year - (month <= 2 ? 1 : 0);
    immutable era = (y >= 0 ? y : y - 399) / 400;
    immutable yoe = y - era * 400;
    immutable doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
    immutable doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    immutable long days = era * 146_097L + doe - 719_468;
    return days * 86_400 + hh * 3600 + mm * 60 + ss < time(null);
}

/// A multipart/form-data body and its boundary (one that appears in none of the parts).
private struct MultipartBody
{
    string body;
    string boundary;
}

private MultipartBody multipartBody(const(string[2])[] fields, const(TestFile)[] files)
{
    string boundary = "andaime-test-boundary-7MA4YWxkTrZu0gW";
    for (uint n = 0;; n++)
    {
        bool clash;
        foreach (ref f; fields)
            clash |= contains(f[1], boundary);
        foreach (ref f; files)
            clash |= contains(cast(const(char)[]) f.bytes, boundary);
        if (!clash)
            break;
        boundary ~= cast(char)('a' + n % 26);
    }
    char[] b;
    foreach (ref f; fields)
        b ~= "--" ~ boundary ~ "\r\nContent-Disposition: form-data; name=\"" ~ f[0] ~ "\"\r\n\r\n" ~ f[1] ~ "\r\n";
    foreach (ref f; files)
        b ~= "--" ~ boundary ~ "\r\nContent-Disposition: form-data; name=\"" ~ f.name ~ "\"; filename=\"" ~ f.filename
            ~ "\"\r\nContent-Type: " ~ f.contentType ~ "\r\n\r\n" ~ cast(const(char)[]) f.bytes ~ "\r\n";
    b ~= "--" ~ boundary ~ "--\r\n";
    return MultipartBody((() @trusted => cast(string) b)(), boundary); // sole owner: safe to make immutable
}

private bool contains(scope const(char)[] hay, scope const(char)[] needle) pure nothrow @nogc
{
    if (needle.length > hay.length)
        return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle)
            return true;
    return false;
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
