/// Streamed responses: a body that is produced while it is being sent (downloads, Server-Sent Events, token streams).
///
///     Stream download(string name)
///     {
///         return Stream("text/csv", (scope StreamWriter w) {
///             foreach (row; rows) w.write(row);        // goes out as it is written; waits if the client is slow
///         });
///     }
///
///     EventStream ticker()
///     {
///         return EventStream((scope EventWriter w) {
///             foreach (i; 0 .. 10) { w.send("tick"); sleep(1.seconds); }
///         });
///     }
///
/// The body runs inside the middleware chain (middleware sees the whole duration and `scope(exit)` blocks run after the
/// stream ends). The head is committed lazily, on the first `write`/`flush` (or when the body returns): a handler that
/// throws before writing anything still gets an ordinary error response. After the commit status and headers are final,
/// an error aborts the response (HTTP/1.1: the connection is closed without the terminating chunk; HTTP/2: the stream is
/// reset) and is logged. A streaming handler holds its fiber and counts toward `ServerConfig.maxInFlight` until it ends.
module andaime.web.stream 2025;

@safe:

import andaime.http.types;
import andaime.http.response : ResponseHead, ResponseSink, ResponseAborted;
import andaime.web.context : Context;
import andaime.web.response_check : checkResponse;

/// Says what a streamed handler produces, for the OpenAPI document: `@produces("text/csv") Stream export_()`.
struct produces { string mediaType; }

/// A streamed body. `body` runs once, with a writer for the bytes.
struct Stream
{
    const(char)[] contentType = "application/octet-stream";
    void delegate(scope StreamWriter w) @system body;
    /// The exact number of bytes the body will write, when known (a file): the response then has a Content-Length and
    /// the transport checks the body against it. -1 = unknown (chunked on HTTP/1.1).
    long contentLength = -1;
    /// Runs once when the response ends, whether `body` ran or not (a HEAD request runs only the head): releases what
    /// the body would read, such as an open file or an upstream response (`ClientStream.close`).
    void delegate() @system done;
}

/// Where a `Stream` body writes. Valid only inside the body.
struct StreamWriter
{
    private Context ctx;

    /// Appends bytes to the response (copied). The first call commits status and headers. May suspend the handler while
    /// the client is slow, and throws `RequestCancelled` if the client goes away.
    void write(scope const(char)[] data)
    {
        commit(ctx);
        ctx.sink.write(data);
    }

    /// Sends what is buffered now and waits until the transport accepted it.
    void flush()
    {
        commit(ctx);
        ctx.sink.flush();
    }
}

/// Server-Sent Events (`text/event-stream`).
struct EventStream
{
    void delegate(scope EventWriter w) @system body;
}

/// Writes events. Each `send`/`comment` is one write plus a flush, so the client sees it at once.
final class EventWriter
{
    private StreamWriter w;
    private char[] buf;

    private this(StreamWriter w) nothrow
    {
        this.w = w;
    }

    /// One event: optional `event:` and `id:` lines, one `data:` line per line of `data`, a blank line.
    /// An event name or id containing CR or LF would let data inject fields: that is a programming error, and it aborts
    /// the stream (an `Exception` with a clear message).
    void send(scope const(char)[] data, scope const(char)[] event = null, scope const(char)[] id = null)
    {
        checkField(event, "event name");
        checkField(id, "event id");
        buf.length = 0;
        if (event.length)
        {
            buf ~= "event: ";
            buf ~= event;
            buf ~= '\n';
        }
        if (id.length)
        {
            buf ~= "id: ";
            buf ~= id;
            buf ~= '\n';
        }
        size_t start = 0;
        for (size_t i = 0; i <= data.length; i++)
        {
            immutable atEnd = i == data.length;
            if (!atEnd && data[i] != '\n' && data[i] != '\r')
                continue;
            buf ~= "data: ";
            buf ~= data[start .. i];
            buf ~= '\n';
            if (!atEnd && data[i] == '\r' && i + 1 < data.length && data[i + 1] == '\n')
                i++; // CRLF is one line break
            start = i + 1;
        }
        buf ~= '\n';
        w.write(buf);
        w.flush();
    }

    /// A comment line (`: text`): a heartbeat that keeps proxies from closing an idle connection.
    void comment(scope const(char)[] text = null)
    {
        checkField(text, "comment");
        buf.length = 0;
        buf ~= ": ";
        buf ~= text;
        buf ~= "\n\n";
        w.write(buf);
        w.flush();
    }

    /// Tells the browser how long to wait before reconnecting.
    void retry(uint milliseconds)
    {
        import andaime.web.numtext : ctNum;

        buf.length = 0;
        buf ~= "retry: ";
        buf ~= ctNum(milliseconds);
        buf ~= "\n\n";
        w.write(buf);
        w.flush();
    }

    private static void checkField(scope const(char)[] s, string what)
    {
        foreach (char c; s)
            if (c == '\r' || c == '\n')
                throw new Exception("andaime: an SSE " ~ what ~ " cannot contain CR or LF");
    }
}

/// Hands the finished response in `ctx` to its sink, the same way for the server and for `TestClient`: head with the
/// body's length, the body (the sink drops it for HEAD, 204 and 304), end. A streamed response was already sent by
/// `runStream`; if it failed after the commit this tells the engine to cut it off.
void sendResponse(Context ctx)
{
    if (ctx.committed)
    {
        if (ctx.aborted)
            throw new ResponseAborted;
        return;
    }
    auto body_ = ctx.response.body.data;
    const ResponseHead head = ResponseHead(ctx.response.status, ctx.response.contentType, ctx.response.headers, body_.length);
    ctx.sink.start(head);
    ctx.sink.write(body_);
    ctx.sink.end();
}

/// `Stream`, `EventStream` and `WithStatus!` of either.
enum isStreamReturn(R) = is(R == Stream) || is(R == EventStream);

// ---- used by dispatch (handler_traits.d); not part of the public API

/// Commits the response head to the sink (status, headers as they are now, unknown length). Once.
package void commit(Context ctx)
{
    if (ctx.committed)
        return;
    if (ctx.sink is null)
        throw new Exception("andaime: a streamed response needs a ResponseSink, and this Context has none");
    if (!checkResponse(ctx))
        throw new Exception("andaime: the response has an invalid header (see the line above)");
    const ResponseHead head = ResponseHead(ctx.response.status, ctx.response.contentType, ctx.response.headers,
        ctx.streamLength);
    ctx.response.lock();
    ctx.committed = true;
    ctx.sink.start(head);
}

/// The single place where a user's stream body is invoked from `@safe` framework code.
/// @trusted: the callee's own safety is the user's business; nothing here touches its memory.
private void callStream(void delegate(scope StreamWriter) @system body, scope StreamWriter w) @trusted
{
    body(w);
}

private void callEvents(void delegate(scope EventWriter) @system body, scope EventWriter w) @trusted
{
    body(w);
}

private void callDone(void delegate() @system done) @trusted
{
    done();
}

/// Runs a stream body as the response (also used by `serveStatic` for big files). Not for application code: return a
/// `Stream` from the handler instead.
void runStream(Context ctx, ref Stream st)
{
    scope (exit)
        if (st.done !is null)
            callDone(st.done);
    ctx.response.contentType = st.contentType;
    ctx.streamLength = st.contentLength;
    runBody(ctx, (StreamWriter w) { if (st.body !is null) callStream(st.body, w); });
}

void runStream(Context ctx, ref EventStream st)
{
    ctx.response.contentType = "text/event-stream";
    ctx.response.setHeader("Cache-Control", "no-cache");
    ctx.response.setHeader("X-Accel-Buffering", "no"); // reverse proxies: do not buffer this
    runBody(ctx, (StreamWriter w) {
        if (st.body !is null)
            callEvents(st.body, new EventWriter(w));
    });
}

private void runBody(Context ctx, scope void delegate(StreamWriter) @safe run)
{
    if (ctx.request.method == Method.HEAD)
    {
        commit(ctx); // the head only: the body is not run
        ctx.sink.end();
        return;
    }
    run(StreamWriter(ctx));
    commit(ctx);   // nothing was written: still a valid, empty stream
    ctx.sink.end();
}
