/// WebSocket routes: the handler returns a `WebSocket`, whose body talks to the client once the connection is upgraded.
///
///     WebSocket chat(string room, Header!"Authorization" auth)
///     {
///         if (!allowed(auth))
///             throw new HttpError(403, "forbidden");    // an ordinary response: no upgrade
///         return WebSocket((scope WsConn ws) {
///             foreach (msg; ws)                         // until the client closes
///                 ws.send(msg.text);
///         });
///     }
///     app.ws!("/chat/{room}", chat);
///
/// Parameters are bound and middleware runs first, exactly as for any GET, so authentication, validation errors and
/// refusals are plain HTTP responses. The `101 Switching Protocols` (HTTP/1.1) or the `200` to the extended CONNECT
/// (HTTP/2, RFC 8441) is committed when the handler returns the `WebSocket`, and the body then runs inside the middleware
/// chain (middleware sees the whole session). When the body returns the connection is closed with 1000; when it throws,
/// with 1011 (and the error is logged). Headers the handler set (`Sec-WebSocket-Protocol`, `Set-Cookie`) go out with
/// that answer.
module andaime.web.websocket 2025;

@safe:

import core.time : Duration, seconds;
import andaime.http.types;
import andaime.http.buffer : ByteBuffer;
import andaime.http.response : ResponseHead, UpgradedConn;
import andaime.http.websocket;
import andaime.web.context : Context;
import andaime.web.params : HttpError;
import andaime.web.response_check : checkResponse;

/// What a WebSocket handler returns: the body that runs on the upgraded connection, and its limits.
struct WebSocket
{
    void delegate(scope WsConn ws) @system body;
    /// Largest message accepted (after decompression); a larger one closes the connection with 1009.
    size_t maxMessageBytes = 1 << 20;
    /// While the body waits in `receive`, a ping goes out after this long without input, and the connection is dropped
    /// after as long again without an answer (dead peers, NAT timeouts). `Duration.zero` disables it.
    Duration pingInterval = 30.seconds;
    /// permessage-deflate (RFC 7692) when the client offers it. Off by default: zlib keeps about 300 KB of state per
    /// connection that sends compressed messages.
    bool compression;
}

/// Runs a WebSocket handler's result: checks the handshake, answers 101 and runs the body. Used by dispatch.
void runWebSocket(Context ctx, ref WebSocket ws)
{
    const(char)[] key;
    final switch (checkUpgradeRequest(ctx.request, key))
    {
        case WsHandshake.ok:
            break;
        case WsHandshake.notUpgrade:
            throw new HttpError(426, "this route only accepts WebSocket connections");
        case WsHandshake.badVersion:
            ctx.response.setHeader("Sec-WebSocket-Version", "13");
            throw new HttpError(426, "unsupported WebSocket version; this server speaks version 13");
        case WsHandshake.badKey:
            throw new HttpError(400, "missing or malformed Sec-WebSocket-Key");
    }
    if (ctx.sink is null)
        throw new Exception("andaime: a WebSocket needs a ResponseSink, and this Context has none");

    WsDeflate deflate;
    scope (failure)
        if (deflate !is null)
            deflate.release();
    DeflateParams dp;
    if (ws.compression && ctx.newDeflate !is null && negotiateDeflate(ctx.request, dp))
    {
        deflate = ctx.newDeflate(dp.serverMaxWindowBits, dp.serverNoContextTakeover);
        if (deflate !is null)
        {
            ByteBuffer ext;
            writeDeflateResponse(ext, dp);
            auto v = ctx.scratch(ext.length);
            v[] = ext.data[];
            ctx.response.setHeader("Sec-WebSocket-Extensions", v);
        }
    }
    // HTTP/1.1 answers 101 with the accept key; HTTP/2 (RFC 8441) answers the extended CONNECT with 200 and no key
    immutable h2 = ctx.request.protocol == Protocol.http2;
    if (!h2)
    {
        auto accept = ctx.scratch(28);
        accept[] = acceptKey(key)[];
        ctx.response.setHeader("Sec-WebSocket-Accept", accept);
    }
    immutable status = h2 ? 200 : 101;
    ctx.response.status = status;
    ctx.response.contentType = null;
    ctx.response.body.clear();
    if (!checkResponse(ctx))
        throw new Exception("andaime: the response has an invalid header (see the line above)");

    const ResponseHead head = ResponseHead(status, null, ctx.response.headers, -1);
    UpgradedConn io = ctx.sink.upgrade(head, "websocket");
    if (io is null)
    {
        ctx.response.removeHeader("Sec-WebSocket-Accept");
        ctx.response.removeHeader("Sec-WebSocket-Extensions");
        throw new HttpError(501, "WebSockets are not available on this connection");
    }
    ctx.response.lock();
    ctx.committed = true;

    // A new object per connection: a WsConn another fiber still holds after this one ended must find it closed, never
    // reach a later connection.
    auto conn = new WsConn;
    WsOptions opts;
    opts.maxMessageBytes = ws.maxMessageBytes;
    opts.pingInterval = ws.pingInterval;
    conn.reset(io, false, opts, deflate);
    deflate = null; // the connection owns it now
    scope (exit)
        conn.abort(); // whatever happened: the transport is closed and the zlib state freed (idempotent)
    try
    {
        if (ws.body !is null)
            callWebSocket(ws.body, conn);
    }
    catch (Exception e)
    {
        try
            conn.close(WsCloseCode.internalError);
        catch (Exception)
        {
        } // the client may be gone already; the error that matters is `e`
        throw e;
    }
    conn.disconnect();
}

/// The single place where a user's WebSocket body is invoked from `@safe` framework code.
/// @trusted: the callee's own safety is the user's business; nothing here touches its memory.
private void callWebSocket(void delegate(scope WsConn) @system body, scope WsConn ws) @trusted
{
    body(ws);
}
