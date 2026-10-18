/// The response contract between the web layer and the engine: a structured head and a sink the body goes into.
/// No I/O here; the engine implements `ResponseSink` (one per request in flight) and so does `TestClient`.
module andaime.http.response 2025;

@safe:

import andaime.http.types;
import andaime.http.buffer;

/// Status line and headers of a response, already validated by the web layer.
struct ResponseHead
{
    int status = 200;
    const(char)[] contentType;        /// null = no Content-Type
    const(HeaderField)[] headers;     /// extra headers; the transport adds Content-Length, Transfer-Encoding, Connection
    long contentLength = -1;          /// -1 = unknown (streamed: chunked on HTTP/1.1, DATA frames on HTTP/2)
}

/// Where a response goes. Obtained from the engine for each request.
///
///     sink.start(head);       // exactly once, before any write
///     sink.write(data);       // any number of times
///     sink.end();             // exactly once
///
/// With a known `contentLength` exactly that many bytes must be written before `end`. `write` and `flush` may suspend the
/// fiber while the client is slow (backpressure), and throw `RequestCancelled` when the client is gone.
interface ResponseSink
{
@safe:
    /// Commits status and headers. Nothing is on the wire yet: the transport sends them with the first body bytes,
    /// or at `flush`/`end`.
    void start(ref const ResponseHead head);

    /// Appends body bytes (copied). Ignored for HEAD, 204 and 304. May suspend the fiber while the client is slow.
    void write(scope const(char)[] data);

    /// Sends what is buffered and waits until the transport accepted it (one Server-Sent Event, say).
    void flush();

    /// Ends the body. With a known `contentLength`, exactly that many bytes must have been written.
    void end();

    /// Hands the connection over to another protocol: from then on its bytes go through the returned `UpgradedConn` (a
    /// WebSocket), never back to HTTP. On HTTP/1.1 it answers `101 Switching Protocols` with `Connection: Upgrade`,
    /// `Upgrade: <protocol>` and `head.headers`; on HTTP/2 the request was an extended CONNECT (RFC 8441), `head` is its
    /// 2xx answer and the `UpgradedConn` is the stream. Instead of `start`; nothing may be written to the sink
    /// afterwards. Returns null when this transport cannot do it (an in-memory sink, the devserver): nothing was sent
    /// then, and an ordinary response can still be given.
    UpgradedConn upgrade(ref const ResponseHead head, scope const(char)[] protocol);
}

/// What `UpgradedConn.fill` found.
enum FillResult : ubyte
{
    data,     /// more bytes are in `buffered()`
    eof,      /// the peer closed its side (or the connection failed); nothing more will arrive
    timeout,  /// the time limit passed first
    stopping, /// the server began a graceful stop; reported once, later calls wait again
}

/// A connection taken over after `101 Switching Protocols`. The engine implements it on the socket, the HTTP client on
/// its own connection, `TestClient` in memory. Reads belong to the fiber that owns the connection (the one that upgraded
/// it); `write` may be called from any fiber of the same worker.
interface UpgradedConn
{
@safe:
    /// Bytes received and not consumed yet. Valid until the next `fill` or `consume`.
    const(ubyte)[] buffered();

    /// Waits until more bytes are appended to `buffered()`, the peer closes, `timeoutMs` passes (-1: no limit) or the
    /// server starts stopping. Throws `RequestCancelled` when the request is cancelled.
    FillResult fill(int timeoutMs);

    /// Drops the first `n` bytes of `buffered()`.
    void consume(size_t n);

    /// Sends `data`. The whole slice is copied before the call can suspend the fiber (backpressure), so the writes of two
    /// fibers never interleave. Throws `RequestCancelled` in the owner's fiber and `WsClosed` (andaime.http.websocket) in any
    /// other fiber when the connection is gone.
    void write(scope const(ubyte)[] data);

    /// Ends the connection once what was written has been sent. Idempotent; reads then report `eof`, writes throw.
    void close();
}

/// Thrown by the glue to tell the engine that a response which already started cannot be completed (the handler failed
/// after bytes were committed). The failure was logged where it happened; the engine just cuts the response off: HTTP/1.1
/// closes the connection without the terminating chunk, HTTP/2 resets the stream.
final class ResponseAborted : Exception
{
    this(string msg = "andaime: the response was aborted after it started") pure nothrow @safe
    {
        super(msg);
    }
}

/// A sink that collects the whole response in memory: the development server, tests, anything that is not a socket.
/// Reuse one object per fiber: `reset()` keeps the buffer.
final class BufferedSink : ResponseSink
{
    ResponseHead head;
    ByteBuffer body;
    bool started, ended;

    void reset() nothrow @nogc
    {
        head = ResponseHead.init;
        body.clear();
        started = ended = false;
    }

    override void start(ref const ResponseHead h)
    {
        head = h;
        started = true;
    }

    override void write(scope const(char)[] data)
    {
        body.put(data);
    }

    override void flush()
    {
    }

    override void end()
    {
        ended = true;
    }

    override UpgradedConn upgrade(ref const ResponseHead h, scope const(char)[] protocol)
    {
        return null; // nothing to take over
    }
}

/// Headers that belong to one HTTP/1.1 connection and are never forwarded or written by the application
/// (RFC 9110 §7.6.1 plus `Content-Length`, which the transport computes).
bool isHopByHop(scope const(char)[] name) pure nothrow @nogc
{
    return equalsIgnoreCase(name, "connection") || equalsIgnoreCase(name, "keep-alive")
        || equalsIgnoreCase(name, "proxy-connection") || equalsIgnoreCase(name, "transfer-encoding")
        || equalsIgnoreCase(name, "upgrade") || equalsIgnoreCase(name, "te") || equalsIgnoreCase(name, "trailer");
}

/// Whether a response with this status has no body at all (RFC 9110 §6.4.1): 1xx, 204, 304.
bool statusHasNoBody(int status) pure nothrow @nogc => status < 200 || status == 204 || status == 304;

/// Writes the HTTP/1.1 status line and headers.
///   `chunked`: `Transfer-Encoding: chunked` (unknown length on HTTP/1.1);
///   otherwise `Content-Length` when the length is known, nothing when it is not (the body then ends when the
///   connection closes, so `keepAlive` must be false).
void writeResponseHead(ref ByteBuffer o, scope ref const ResponseHead head, bool keepAlive, bool chunked) nothrow @nogc
{
    o.put("HTTP/1.1 ");
    o.putUint(head.status);
    o.put(' ');
    o.put(statusText(head.status));
    o.put("\r\n");
    if (head.contentType.length)
    {
        o.put("Content-Type: ");
        o.put(head.contentType);
        o.put("\r\n");
    }
    // 1xx, 204 and 304 carry no body or Content-Length (RFC 9110 §8.6)
    if (!statusHasNoBody(head.status))
    {
        if (chunked)
            o.put("Transfer-Encoding: chunked\r\n");
        else if (head.contentLength >= 0)
        {
            o.put("Content-Length: ");
            o.putUint(cast(ulong) head.contentLength);
            o.put("\r\n");
        }
    }
    foreach (ref h; head.headers)
    {
        o.put(h.name);
        o.put(": ");
        o.put(h.value);
        o.put("\r\n");
    }
    if (!keepAlive)
        o.put("Connection: close\r\n");
    o.put("\r\n");
}

unittest
{
    ByteBuffer b;
    const HeaderField[1] x = [HeaderField("X-Id", "7")];
    auto head = ResponseHead(201, "application/json", x[], 2);
    writeResponseHead(b, head, false, false);
    assert(b.data == "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n"
        ~ "Content-Length: 2\r\nX-Id: 7\r\nConnection: close\r\n\r\n", b.data.idup);

    b.clear();
    auto streamed = ResponseHead(200, "text/event-stream", null, -1);
    writeResponseHead(b, streamed, true, true);
    assert(b.data == "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n", b.data.idup);

    b.clear();
    writeResponseHead(b, streamed, false, false); // HTTP/1.0 client: the body ends with the connection
    assert(b.data == "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n", b.data.idup);

    b.clear();
    auto none = ResponseHead(204, null, null, 0);
    writeResponseHead(b, none, true, false);
    assert(b.data == "HTTP/1.1 204 No Content\r\n\r\n", b.data.idup);

    b.clear();
    auto switching = ResponseHead(101, null, null, 0);
    writeResponseHead(b, switching, true, false);
    assert(b.data == "HTTP/1.1 101 Switching Protocols\r\n\r\n", b.data.idup);

    assert(isHopByHop("Transfer-Encoding") && isHopByHop("TE") && !isHopByHop("X-Id"));
    assert(statusHasNoBody(204) && statusHasNoBody(304) && statusHasNoBody(100) && !statusHasNoBody(200));
}
