/// HTTP/2 (RFC 9113), server side, without I/O.
///
/// `H2Session` is a state machine for one connection: the engine hands it the bytes it read
/// (`receive`), runs the requests it reports as ready (`popReady`), gives back each handler's
/// response (`respond`) and sends whatever is in `pendingOutput`. Everything about the protocol
/// lives here — frames, HPACK, stream states, flow control in both directions, validation,
/// errors — so it can be unit-tested and fuzzed without sockets, like the HTTP/1 parser.
///
/// Responses arrive as a structured `ResponseHead` plus body bytes (`respond`, or `beginResponse`/`sendData`/
/// `endResponse` for a streamed body) and are encoded here: the status becomes `:status`, names are lowercased,
/// connection-specific fields are dropped. Handlers, middleware and the web layer do not know which protocol they are
/// serving.
///
/// What is deliberately absent: server push (disabled by RFC 9113 clients anyway), priorities
/// (parsed and ignored, as RFC 9113 allows), the HPACK dynamic table on the encoding side.
module vela.http.h2;

@safe:

import vela.http.types;
import vela.http.buffer;
import vela.http.response : ResponseHead, isHopByHop;
import vela.http.hpack;
import vela.http.parser : Limits;

/// The 24 bytes a client sends first (RFC 9113 §3.4).
enum string clientPreface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

enum H2Error : uint
{
    noError = 0x0,
    protocol = 0x1,
    internal = 0x2,
    flowControl = 0x3,
    settingsTimeout = 0x4,
    streamClosed = 0x5,
    frameSize = 0x6,
    refusedStream = 0x7,
    cancel = 0x8,
    compression = 0x9,
    connect = 0xa,
    enhanceYourCalm = 0xb,
    inadequateSecurity = 0xc,
    http11Required = 0xd,
}

enum FrameType : ubyte
{
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rstStream = 0x3,
    settings = 0x4,
    pushPromise = 0x5,
    ping = 0x6,
    goAway = 0x7,
    windowUpdate = 0x8,
    continuation = 0x9,
}

enum : ubyte
{
    flagEndStream = 0x1,
    flagAck = 0x1,
    flagEndHeaders = 0x4,
    flagPadded = 0x8,
    flagPriority = 0x20,
}

private enum : ushort
{
    settingHeaderTableSize = 0x1,
    settingEnablePush = 0x2,
    settingMaxConcurrentStreams = 0x3,
    settingInitialWindowSize = 0x4,
    settingMaxFrameSize = 0x5,
    settingMaxHeaderListSize = 0x6,
    settingEnableConnectProtocol = 0x8, // RFC 8441
}

/// How long a tunnel whose side we ended waits for the peer's END_STREAM before it is reset (`H2Session.tick`).
private enum long tunnelLingerMs = 1000;

private enum long maxWindow = int.max; // 2^31 - 1
private enum uint defaultWindow = 65_535;
private enum uint defaultFrameSize = 16_384;

struct H2Config
{
    uint maxConcurrentStreams = 100;  /// SETTINGS_MAX_CONCURRENT_STREAMS we announce
    /// Per-stream receive window we announce (SETTINGS_INITIAL_WINDOW_SIZE): how much of one request
    /// body the client may send per round trip. Bodies are buffered whole anyway (`limits.maxBodyBytes`),
    /// so this trades nothing but throughput. Clamped to [65,535, 2^31 - 1].
    uint initialWindowSize = 256 << 10;
    /// Connection receive window (raised with WINDOW_UPDATE at start): request body bytes in flight
    /// across all streams of a connection. Clamped to [65,535, 2^31 - 1].
    uint connectionWindowSize = 1 << 20;
    uint headerTableSize = 4096;      /// HPACK table we keep for the peer
    uint maxHeaders = 32;             /// fields per request; above that, 431
    uint floodLimit = 1000;           /// cost of control frames/resets before ENHANCE_YOUR_CALM (halves every `tick`)
    size_t outputHighWater = 64 << 10; /// DATA stops being queued while this much output is pending
    /// A client that has not acknowledged our SETTINGS by then gets GOAWAY(SETTINGS_TIMEOUT) (§6.5.3).
    uint settingsTimeoutMs = 10_000;
    /// Announces SETTINGS_ENABLE_CONNECT_PROTOCOL and accepts extended CONNECT with `:protocol websocket` (RFC 8441):
    /// WebSockets as streams of the connection. Such a stream is a tunnel, see `tunnelInput`.
    bool enableConnectProtocol = true;
    Limits limits;                   /// maxHeadBytes = decoded header list; maxTargetBytes = :path; maxBodyBytes
}

enum StreamState : ubyte { idle, open, halfClosedRemote, halfClosedLocal, closed }

/// One request/response exchange. Owned by the session; the engine borrows it from `popReady`
/// until `respond` (or, if the peer reset it, until `detach`).
final class H2Stream
{
    uint id;
    StreamState state;

    /// The request, valid once the stream was reported by `popReady`. Its slices point into
    /// this object (`fieldBytes`, `body`) and stay valid until `respond`/`detach`.
    Request req;
    /// Engine data (the fiber running the handler). The session never looks inside.
    Object task;
    /// Engine bookkeeping (deadlines). The session never looks at it.
    long deadlineMs;
    /// Session clock (`H2Session.nowMs`) when the HEADERS arrived.
    long openedMs;
    /// Peer sent RST_STREAM (or the connection failed) while the engine held the stream.
    bool resetByPeer;
    /// An extended CONNECT (RFC 8441): the request is handed out when its HEADERS arrive, and once the response is 2xx
    /// the stream carries bytes both ways (`tunnelInput`/`tunnelConsume` in, `sendData` out) until either side ends it.
    bool tunnel;

private:
    ByteBuffer fieldBytes;           // decoded names and values, back to back
    uint[4][] fieldRefs;             // name offset, name length, value offset, value length
    size_t fieldCount, listSize;
    HeaderField[] store;
    ByteBuffer body;
    ByteBuffer response;
    size_t sendPos, sendEnd;
    long sendWindow, recvWindow;
    uint recvConsumed;
    long contentLength = -1;
    size_t received;
    bool sawRegular, sawMethod, sawScheme, sawPath, sawAuthority;
    bool malformed, tooLarge, cookieCrumbs, gotHeaders, queued, responding, endSent;
    bool bodyDone;                   // the whole response body is in `response` (nothing more will be appended)
    int earlyStatus;                 // answered by the session itself, no handler
    uint[4] pseudo;                  // [off, len] of :method and :path in fieldBytes
    uint[2] authority;
    uint[2] scheme;
    uint[2] protocol;                // :protocol (extended CONNECT)
    bool sawProtocol;
    bool tunnelUp;                   // a tunnel answered 2xx: ending our side half-closes it instead of resetting it
    bool inputQueued;                // in the session's `inputQ`
    size_t inPos;                    // tunnel: bytes of `body` the engine already consumed
    long lingerSinceMs;              // tunnel half-closed by us: first `tick` that saw it (0 = not yet)

    this(uint maxHeaders) nothrow
    {
        fieldRefs = new uint[4][maxHeaders];
        store = new HeaderField[maxHeaders + 1]; // + host synthesized from :authority
    }

    void reset() nothrow @nogc
    {
        id = 0;
        state = StreamState.idle;
        req = Request.init;
        task = null;
        deadlineMs = openedMs = 0;
        resetByPeer = false;
        fieldBytes.clear();
        fieldBytes.shrinkTo(16 << 10);
        fieldCount = listSize = 0;
        body.clear();
        body.shrinkTo(64 << 10);
        response.clear();
        response.shrinkTo(64 << 10);
        sendPos = sendEnd = 0;
        sendWindow = recvWindow = 0;
        recvConsumed = 0;
        contentLength = -1;
        received = 0;
        sawRegular = sawMethod = sawScheme = sawPath = sawAuthority = false;
        malformed = tooLarge = cookieCrumbs = gotHeaders = queued = responding = endSent = bodyDone = false;
        earlyStatus = 0;
        pseudo[] = 0;
        authority[] = 0;
        scheme[] = 0;
        protocol[] = 0;
        tunnel = sawProtocol = tunnelUp = inputQueued = false;
        inPos = 0;
        lingerSinceMs = 0;
    }

    /// Element-wise on purpose: assigning an array literal may allocate it on the GC first.
    void setRef(size_t i, size_t nameOff, size_t nameLen, size_t valueOff, size_t valueLen) nothrow @nogc
    {
        fieldRefs[i][0] = cast(uint) nameOff;
        fieldRefs[i][1] = cast(uint) nameLen;
        fieldRefs[i][2] = cast(uint) valueOff;
        fieldRefs[i][3] = cast(uint) valueLen;
    }

    void releaseMemory() nothrow @nogc
    {
        fieldBytes.shrinkTo(0);
        body.shrinkTo(0);
        response.shrinkTo(0);
    }
}

/// State of one HTTP/2 connection, server side.
final class H2Session
{
    H2Config cfg;
    /// The engine's clock, stamped on new streams (`H2Stream.openedMs`). Set before `receive`.
    long nowMs;

    private HpackDecoder hpack;
    private ByteBuffer outbox;
    private size_t outPos;
    private ByteBuffer hblock;        // header block being assembled (HEADERS + CONTINUATIONs)
    private ByteBuffer hpackOut;      // response header block scratch
    private uint hblockStream;        // stream of the block in progress (0 = none)
    private ubyte hblockFlags;        // flags of the HEADERS that started it
    private bool hblockSelfDep;

    private Vec streams;              // open, half-closed or still sending
    private Vec spare;
    private Vec readyQ, resetQ, sending;
    private Vec inputQ;               // tunnels with new input or the peer's END_STREAM (`popInput`)
    private size_t readyPos, resetPos;
    private size_t zombies;           // streams reset by the peer that the engine still holds

    private uint[64] recentId;        // recently closed streams (to tell STREAM_CLOSED from PROTOCOL_ERROR)
    private ubyte[64] recentHow;      // 1 = closed normally, 2 = reset by the peer, 3 = reset by us
    private size_t recentNext;

    private uint lastPeerStream;
    private long connSendWindow = defaultWindow;
    private long connRecvWindow = defaultWindow;
    private uint connRecvConsumed;
    private long peerInitialWindow = defaultWindow;
    private uint peerMaxFrame = defaultFrameSize;
    private uint flood;
    private size_t prefaceSeen;
    private bool settingsSeen;
    private bool started;
    private bool settingsAcked;
    private long settingsSentMs;

    /// GOAWAY sent (graceful or not): no new streams will be processed.
    bool goAwaySent;
    /// Peer sent GOAWAY.
    bool goAwayReceived;
    /// Connection error: close once `pendingOutput` is flushed.
    bool fatal;
    /// Error code of the GOAWAY we sent, for logs and tests.
    H2Error lastError;
    /// Size the next `receive` needs at least (frame header + payload), for the engine's buffer.
    size_t needBytes = clientPreface.length;

    this(H2Config c = H2Config.init) nothrow
    {
        cfg = c;
        cfg.initialWindowSize = clampWindow(c.initialWindowSize);
        cfg.connectionWindowSize = clampWindow(c.connectionWindowSize);
        hpack.setMaxAllowed(c.headerTableSize);
        // a string can never be longer than the block it came in (Huffman expands at most 8/5);
        // the header-list limit (431) is checked per request, this only bounds the scratch space
        hpack.maxStringBytes = maxCompressedBlock * 2;
    }

    /// Back to the initial state, keeping buffers (the engine pools sessions).
    void reset() nothrow
    {
        // the engine has cancelled and detached every task before resetting the session
        foreach (s; streams[])
            recycle(s);
        foreach (s; readyQ[])
            if (s !is null)
                recycle(s);
        streams.clear();
        readyQ.clear();
        resetQ.clear();
        sending.clear();
        inputQ.clear();
        readyPos = resetPos = zombies = 0;
        hpack.reset();
        outbox.clear();
        outbox.shrinkTo(64 << 10);
        outPos = 0;
        hblock.clear();
        hblock.shrinkTo(16 << 10);
        hblockStream = 0;
        recentId[] = 0;
        recentHow[] = 0;
        recentNext = 0;
        lastPeerStream = 0;
        connSendWindow = connRecvWindow = defaultWindow;
        connRecvConsumed = 0;
        peerInitialWindow = defaultWindow;
        peerMaxFrame = defaultFrameSize;
        flood = 0;
        prefaceSeen = 0;
        settingsSeen = started = settingsAcked = false;
        settingsSentMs = 0;
        goAwaySent = goAwayReceived = fatal = false;
        lastError = H2Error.noError;
        needBytes = clientPreface.length;
    }

    /// Drops every buffer now: for a session that will not be reused (the collector reclaims the blocks
    /// once no slice refers to them).
    void releaseMemory() nothrow
    {
        reset();
        outbox.shrinkTo(0);
        hblock.shrinkTo(0);
        hpackOut.shrinkTo(0);
        hpack.releaseMemory();
        while (spare.length)
            spare.pop().releaseMemory();
    }

    // ================================================================ engine interface

    /// Queues the server preface (our SETTINGS). Call once, before anything else.
    void start() nothrow
    {
        if (started)
            return;
        started = true;
        settingsSentMs = nowMs;
        ubyte[24] p;
        size_t n = 0;
        void setting(ushort id, uint v) nothrow @nogc @safe
        {
            p[n] = cast(ubyte)(id >> 8); p[n + 1] = cast(ubyte) id;
            p[n + 2] = cast(ubyte)(v >> 24); p[n + 3] = cast(ubyte)(v >> 16);
            p[n + 4] = cast(ubyte)(v >> 8); p[n + 5] = cast(ubyte) v;
            n += 6;
        }
        setting(settingMaxConcurrentStreams, cfg.maxConcurrentStreams);
        if (cfg.initialWindowSize != defaultWindow)
            setting(settingInitialWindowSize, cfg.initialWindowSize);
        setting(settingMaxHeaderListSize, cast(uint) cfg.limits.maxHeadBytes);
        if (cfg.enableConnectProtocol)
            setting(settingEnableConnectProtocol, 1);
        frameHeader(n, FrameType.settings, 0, 0);
        outbox.put(cast(const(char)[]) p[0 .. n]);
        if (cfg.connectionWindowSize > defaultWindow)
        {
            windowUpdate(0, cfg.connectionWindowSize - defaultWindow);
            connRecvWindow = cfg.connectionWindowSize;
        }
    }

    /// h2c upgrade (RFC 7540 §3.2): the HTTP/1.1 request that asked for it becomes stream 1,
    /// half-closed, and `settings` (the decoded HTTP2-Settings header) apply as the peer's
    /// SETTINGS. Queues the 101 response, then the server preface. Returns false if the
    /// settings are invalid (answer the request over HTTP/1.1 instead).
    bool startUpgrade(ref const Request h1, scope const(ubyte)[] reqBody, scope const(ubyte)[] settings) nothrow
    {
        if (settings.length % 6 != 0)
            return false;
        foreach (i; 0 .. settings.length / 6)
            if (applySetting(settings[i * 6 .. i * 6 + 6]) != H2Error.noError)
                return false;
        outbox.put("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n");
        start();

        auto s = newStream(1);
        lastPeerStream = 1;
        s.gotHeaders = true;
        s.state = StreamState.halfClosedRemote;
        s.fieldBytes.put(methodName(h1.method));
        s.pseudo[0] = 0;
        s.pseudo[1] = cast(uint) s.fieldBytes.length;
        s.pseudo[2] = cast(uint) s.fieldBytes.length;
        s.fieldBytes.put(h1.target);
        s.pseudo[3] = cast(uint) h1.target.length;
        s.sawMethod = s.sawPath = s.sawScheme = true;
        foreach (ref h; h1.headers)
        {
            if (isConnectionSpecific(h.name) || equalsIgnoreCase(h.name, "http2-settings"))
                continue;
            if (s.fieldCount == s.fieldRefs.length)
            {
                s.tooLarge = true;
                break;
            }
            s.setRef(s.fieldCount++, s.fieldBytes.length, h.name.length, s.fieldBytes.length + h.name.length,
                h.value.length);
            s.fieldBytes.put(h.name);
            s.fieldBytes.put(h.value);
        }
        s.body.put(cast(const(char)[]) reqBody);
        s.received = reqBody.length;
        finishRequest(s);
        return true;
    }

    /// Processes every complete frame in `input`; returns how many bytes were consumed (keep
    /// the rest and call again with more). After a connection error the whole input is consumed.
    size_t receive(scope const(ubyte)[] input) nothrow
    {
        if (!started)
            start();
        size_t p = 0;
        if (prefaceSeen < clientPreface.length)
        {
            immutable n = input.length < clientPreface.length - prefaceSeen
                ? input.length : clientPreface.length - prefaceSeen;
            if (cast(const(char)[]) input[0 .. n] != clientPreface[prefaceSeen .. prefaceSeen + n])
            {
                connectionError(H2Error.protocol);
                return input.length;
            }
            prefaceSeen += n;
            p = n;
            if (prefaceSeen < clientPreface.length)
            {
                needBytes = clientPreface.length - prefaceSeen;
                return p;
            }
        }
        while (!fatal)
        {
            if (input.length - p < 9)
            {
                needBytes = 9;
                break;
            }
            immutable len = (cast(uint) input[p] << 16) | (cast(uint) input[p + 1] << 8) | input[p + 2];
            immutable type = input[p + 3];
            immutable flags = input[p + 4];
            immutable sid = readU32(input[p + 5 .. p + 9]) & 0x7fff_ffff;
            if (len > defaultFrameSize) // we never raise SETTINGS_MAX_FRAME_SIZE
            {
                connectionError(H2Error.frameSize);
                break;
            }
            if (input.length - p < 9 + len)
            {
                needBytes = 9 + len;
                break;
            }
            onFrame(type, flags, sid, input[p + 9 .. p + 9 + len]);
            p += 9 + len;
            if (flood > cfg.floodLimit)
                connectionError(H2Error.enhanceYourCalm);
        }
        pump();
        return fatal ? input.length : p;
    }

    /// Next request ready to run (all headers and body received), in arrival order.
    bool popReady(out H2Stream s) nothrow
    {
        while (readyPos < readyQ.length)
        {
            auto c = readyQ[readyPos];
            readyQ[readyPos++] = null;
            c.queued = false;
            if ((c.state == StreamState.halfClosedRemote || (c.tunnel && c.state == StreamState.open)) && !c.responding)
            {
                s = c;
                if (readyPos == readyQ.length)
                {
                    readyQ.clear();
                    readyPos = 0;
                }
                return true;
            }
            if (c.state == StreamState.closed && c.task is null)
                recycle(c); // reset while it waited in the queue
        }
        readyQ.clear();
        readyPos = 0;
        return false;
    }

    /// Next stream whose running handler must be cancelled (peer RST_STREAM or a stream
    /// error). Give it back with `detach` once its task has unwound.
    bool popReset(out H2Stream s) nothrow @nogc
    {
        if (resetPos >= resetQ.length)
        {
            resetQ.clear();
            resetPos = 0;
            return false;
        }
        s = resetQ[resetPos];
        resetQ[resetPos++] = null;
        return true;
    }

    /// The handler's whole response. Takes the body's memory by swapping it with the stream's (no copy); `body_` comes
    /// back empty. The head's slices are only read during the call.
    void respond(H2Stream s, ref const ResponseHead head, ref ByteBuffer body_) nothrow
    {
        s.task = null;
        if (s.resetByPeer || s.state == StreamState.closed || s.state == StreamState.idle)
        {
            detach(s);
            return;
        }
        s.response.clear();
        s.response.swap(body_);
        s.sendPos = 0;
        s.sendEnd = s.response.length;
        s.bodyDone = true;
        sendHead(s, head, s.sendEnd == 0);
        pump();
    }

    // ---- a response whose body is produced while it is being sent (SSE, downloads). The engine keeps `s.task` set
    // until `endResponse`, so the stream is not recycled under the handler.

    /// Sends HEADERS and starts the body. `endStream`: there is no body at all.
    void beginResponse(H2Stream s, ref const ResponseHead head, bool endStream) nothrow
    {
        if (s.resetByPeer || s.state == StreamState.closed || s.state == StreamState.idle || s.responding)
            return; // the peer reset it: the engine learns it from popReset
        s.response.clear();
        s.sendPos = s.sendEnd = 0;
        s.bodyDone = endStream;
        s.tunnelUp = s.tunnel && !endStream && head.status >= 200 && head.status < 300;
        sendHead(s, head, endStream);
        pump();
    }

    /// Queues body bytes (copied) and moves what the windows allow into the output. Returns how many bytes of this
    /// stream are still waiting to be sent: the engine suspends the handler when that is above its high-water mark.
    size_t sendData(H2Stream s, scope const(char)[] data) nothrow
    {
        if (!s.responding || s.bodyDone || s.endSent || s.resetByPeer || s.state == StreamState.closed)
            return 0;
        s.response.put(data);
        s.sendEnd = s.response.length;
        pump();
        return s.sendEnd - s.sendPos;
    }

    /// Bytes of the stream's body queued but not yet sent.
    size_t pendingBytes(const H2Stream s) const nothrow @nogc => s.sendEnd - s.sendPos;

    /// The body is complete. END_STREAM goes out with the last DATA frame (or on its own if everything was sent). The
    /// engine hands the stream back: it must not touch it afterwards.
    void endResponse(H2Stream s) nothrow
    {
        s.task = null;
        if (!s.responding || s.endSent || s.resetByPeer || s.state == StreamState.closed || s.state == StreamState.idle)
        {
            detach(s);
            return;
        }
        s.bodyDone = true;
        if (s.sendPos == s.sendEnd)
        {
            sending.remove(s);
            frameHeader(0, FrameType.data, flagEndStream, s.id);
            endSent(s);
        }
        pump();
    }

    // ---- a tunnel (extended CONNECT, RFC 8441: a WebSocket). The engine answers it with `beginResponse` (2xx, no
    // END_STREAM), writes with `sendData`, reads with `tunnelInput`/`tunnelConsume`, and ends its side with `endResponse`.
    // The stream window is credited only as the engine consumes, so a peer can never queue more than one window.

    /// Next tunnel with new input, or whose peer ended or reset it, since the last call. A stream may come back more
    /// than once; one that ended meanwhile is never handed out.
    bool popInput(out H2Stream s) nothrow @nogc
    {
        while (inputQ.length)
        {
            auto c = inputQ.pop();
            c.inputQueued = false;
            if (c.task !is null)
            {
                s = c;
                return true;
            }
        }
        return false;
    }

    /// Bytes the peer sent on the tunnel that the engine has not consumed yet. Valid until the next `receive` or
    /// `tunnelConsume`.
    const(ubyte)[] tunnelInput(const H2Stream s) const nothrow @nogc
    {
        return cast(const(ubyte)[]) s.body.data[s.inPos .. $];
    }

    /// The engine consumed `n` bytes of `tunnelInput`; the peer may send that much more (WINDOW_UPDATE).
    void tunnelConsume(H2Stream s, size_t n) nothrow
    {
        assert(s.inPos + n <= s.body.length, "vela: consumed more than the tunnel received");
        s.inPos += n;
        if (s.inPos == s.body.length)
        {
            s.body.clear();
            s.body.shrinkTo(16 << 10); // an idle tunnel does not keep a big block
            s.inPos = 0;
        }
        else if (s.inPos >= s.body.length / 2)
        {
            s.body.dropFront(s.inPos); // what is left is at most half: the copy is amortized
            s.inPos = 0;
        }
        if (s.state == StreamState.open)
            creditStream(s, n);
    }

    /// The peer will send nothing more on the tunnel (END_STREAM, RST_STREAM, or the connection failed).
    bool tunnelEnded(const H2Stream s) const nothrow @nogc
    {
        return s.state != StreamState.open || s.resetByPeer;
    }

    /// Engine is done with a stream it got from `popReady`/`popReset` without responding.
    void detach(H2Stream s) nothrow
    {
        s.task = null;
        if (s.resetByPeer && zombies)
            zombies--;
        if (s.state == StreamState.closed || s.resetByPeer)
            recycle(s);
    }

    /// Resets a stream from the engine side (e.g. REFUSED_STREAM when it cannot run it).
    void cancelStream(H2Stream s, H2Error code) nothrow
    {
        s.task = null;
        if (s.state != StreamState.closed && s.state != StreamState.idle)
            resetStream(s, code);
        else
            detach(s);
        pump();
    }

    /// Bytes waiting to be written to the socket.
    const(char)[] pendingOutput() const nothrow @nogc return => outbox.data[outPos .. $];

    /// `n` bytes of `pendingOutput` reached the socket.
    void sent(size_t n) nothrow
    {
        outPos += n;
        if (outPos == outbox.length)
        {
            outbox.clear();
            outPos = 0;
            outbox.shrinkTo(256 << 10);
        }
        pump();
    }

    /// Graceful shutdown: GOAWAY(NO_ERROR); streams already accepted run to completion.
    void goAway() nothrow
    {
        if (goAwaySent)
            return;
        goAwayFrame(H2Error.noError);
    }

    /// Whether the engine should keep reading (false while too much output is queued:
    /// a peer that sends but does not read must not grow our memory).
    bool wantsRead() const nothrow @nogc => !fatal && outbox.length - outPos < (1 << 20);

    /// Nothing left to do: close once `pendingOutput` is empty.
    bool finished() const nothrow @nogc
    {
        return fatal || ((goAwaySent || goAwayReceived) && streams.length == 0 && zombies == 0);
    }

    /// Streams currently open or sending (for deadlines). Do not keep the slice.
    H2Stream[] activeStreams() nothrow @nogc return => streams[];

    /// Number of streams the engine still holds or that still have bytes to send.
    size_t busy() const nothrow @nogc => streams.length + zombies;

    /// Called periodically (every few hundred ms): forgets old flood points, resets tunnels whose peer never ended.
    void tick(long now) nothrow
    {
        flood /= 2;
        for (size_t i = streams.length; i-- > 0;)
        {
            auto s = streams[i];
            if (s.state != StreamState.halfClosedLocal || s.task !is null)
                continue;
            if (s.lingerSinceMs == 0)
                s.lingerSinceMs = now | 1;
            else if (now - s.lingerSinceMs >= tunnelLingerMs)
            {
                resetStream(s, H2Error.noError); // removes it from `streams`: indices below are unaffected
                pump();
            }
        }
        if (started && !settingsAcked && !fatal && cfg.settingsTimeoutMs && now - settingsSentMs > cfg.settingsTimeoutMs)
            connectionError(H2Error.settingsTimeout);
    }

    /// A stream that never completed its request in time: answered with `status` (408).
    void timeoutStream(H2Stream s, int status) nothrow
    {
        if (s.state == StreamState.open && !s.responding && !s.queued)
            answerEarly(s, status);
        pump();
    }

    // ================================================================ frames in

    private void onFrame(ubyte type, ubyte flags, uint sid, scope const(ubyte)[] payload) nothrow
    {
        if (!settingsSeen)
        {
            // RFC 9113 §3.4: the preface ends with a SETTINGS frame
            if (type != FrameType.settings || (flags & flagAck))
                return connectionError(H2Error.protocol);
            settingsSeen = true;
        }
        if (hblockStream && type != FrameType.continuation)
            return connectionError(H2Error.protocol); // a header block must not be interrupted
        switch (type)
        {
            case FrameType.data: return onData(flags, sid, payload);
            case FrameType.headers: return onHeaders(flags, sid, payload);
            case FrameType.priority: return onPriority(sid, payload);
            case FrameType.rstStream: return onRstStream(sid, payload);
            case FrameType.settings: return onSettings(flags, sid, payload);
            case FrameType.pushPromise: return connectionError(H2Error.protocol); // clients never push
            case FrameType.ping: return onPing(flags, sid, payload);
            case FrameType.goAway: return onGoAway(sid, payload);
            case FrameType.windowUpdate: return onWindowUpdate(sid, payload);
            case FrameType.continuation: return onContinuation(flags, sid, payload);
            default: return; // unknown frame types are ignored (§5.5)
        }
    }

    private void onData(ubyte flags, uint sid, scope const(ubyte)[] payload) nothrow
    {
        if (sid == 0)
            return connectionError(H2Error.protocol);
        // flow control covers the whole payload, padding included, whatever the stream's state
        immutable flowLen = payload.length;
        if (flowLen > connRecvWindow)
            return connectionError(H2Error.flowControl);
        connRecvWindow -= flowLen;
        connRecvConsumed += cast(uint) flowLen;
        if (connRecvConsumed >= cfg.connectionWindowSize / 2)
        {
            windowUpdate(0, connRecvConsumed);
            connRecvWindow += connRecvConsumed;
            connRecvConsumed = 0;
        }
        const(ubyte)[] data;
        if (!unpad(flags, payload, data))
            return connectionError(H2Error.protocol);
        if (data.length == 0 && !(flags & flagEndStream))
            flood++;

        auto s = find(sid);
        if (s is null)
        {
            if (sid > lastPeerStream)
                return connectionError(H2Error.protocol); // idle stream
            if (recentlyClosed(sid) == 3)
                return; // we reset it; frames in flight are expected
            return sendRst(sid, H2Error.streamClosed);
        }
        if (s.tunnel)
            return tunnelData(s, flags, flowLen, data);
        if (s.state != StreamState.open)
            return resetStream(s, H2Error.streamClosed);
        if (flowLen > s.recvWindow)
            return resetStream(s, H2Error.flowControl);
        s.recvWindow -= flowLen;
        s.received += data.length;
        if (s.contentLength >= 0 && s.received > s.contentLength)
            return resetStream(s, H2Error.protocol);
        if (!s.earlyStatus)
        {
            if (s.body.length + data.length > cfg.limits.maxBodyBytes)
                return answerEarly(s, 413);
            s.body.put(cast(const(char)[]) data);
        }
        if (flags & flagEndStream)
            return endOfRequest(s);
        s.recvConsumed += cast(uint) flowLen;
        if (s.recvConsumed >= cfg.initialWindowSize / 2)
        {
            windowUpdate(s.id, s.recvConsumed);
            s.recvWindow += s.recvConsumed;
            s.recvConsumed = 0;
        }
    }

    /// DATA on a tunnel: kept for the engine (no body limit: the stream window bounds it), or dropped once our side ended.
    private void tunnelData(H2Stream s, ubyte flags, size_t flowLen, scope const(ubyte)[] data) nothrow
    {
        if (s.state != StreamState.open && s.state != StreamState.halfClosedLocal)
            return resetStream(s, H2Error.streamClosed);
        if (flowLen > s.recvWindow)
            return resetStream(s, H2Error.flowControl);
        s.recvWindow -= flowLen;
        if (s.state == StreamState.halfClosedLocal)
        {
            // we ended our side (the WebSocket is closing): what still arrives is dropped
            if (flags & flagEndStream)
                return closeStream(s, 1);
            return creditStream(s, flowLen);
        }
        s.body.put(cast(const(char)[]) data);
        if (flowLen > data.length)
            creditStream(s, flowLen - data.length); // padding never reaches the engine
        if (flags & flagEndStream)
            s.state = StreamState.halfClosedRemote;
        if (data.length || (flags & flagEndStream))
            queueInput(s);
    }

    private void queueInput(H2Stream s) nothrow
    {
        if (!s.inputQueued)
        {
            s.inputQueued = true;
            inputQ.push(s);
        }
    }

    /// `n` bytes of the stream's receive window were used up and may be given back to the peer.
    private void creditStream(H2Stream s, size_t n) nothrow
    {
        s.recvConsumed += cast(uint) n;        if (s.recvConsumed >= cfg.initialWindowSize / 2)
        {
            windowUpdate(s.id, s.recvConsumed);
            s.recvWindow += s.recvConsumed;
            s.recvConsumed = 0;
        }
    }

    private void onHeaders(ubyte flags, uint sid, scope const(ubyte)[] payload) nothrow
    {
        if (sid == 0)
            return connectionError(H2Error.protocol);
        const(ubyte)[] frag;
        if (!unpad(flags, payload, frag))
            return connectionError(H2Error.protocol);
        hblockSelfDep = false;
        if (flags & flagPriority)
        {
            if (frag.length < 5)
                return connectionError(H2Error.frameSize);
            hblockSelfDep = (readU32(frag[0 .. 4]) & 0x7fff_ffff) == sid;
            frag = frag[5 .. $];
        }
        hblock.clear();
        hblock.put(cast(const(char)[]) frag);
        hblockFlags = flags;
        if (flags & flagEndHeaders)
            headerBlockDone(sid);
        else
            hblockStream = sid;
    }

    private void onContinuation(ubyte flags, uint sid, scope const(ubyte)[] payload) nothrow
    {
        if (hblockStream == 0 || sid != hblockStream)
            return connectionError(H2Error.protocol);
        if (hblock.length + payload.length > maxCompressedBlock)
            return connectionError(H2Error.enhanceYourCalm); // CONTINUATION flood
        if (payload.length == 0 && !(flags & flagEndHeaders))
            flood++;
        hblock.put(cast(const(char)[]) payload);
        if (flags & flagEndHeaders)
        {
            hblockStream = 0;
            headerBlockDone(sid);
        }
    }

    private size_t maxCompressedBlock() const nothrow @nogc => cfg.limits.maxHeadBytes * 2 + defaultFrameSize;

    private void onPriority(uint sid, scope const(ubyte)[] payload) nothrow
    {
        if (sid == 0)
            return connectionError(H2Error.protocol);
        flood++;
        if (payload.length != 5)
        {
            auto s = find(sid);
            if (s !is null)
                return resetStream(s, H2Error.frameSize);
            return sendRst(sid, H2Error.frameSize);
        }
        if ((readU32(payload[0 .. 4]) & 0x7fff_ffff) == sid)
        {
            auto s = find(sid);
            if (s !is null)
                return resetStream(s, H2Error.protocol);
            return sendRst(sid, H2Error.protocol);
        }
        // priorities are advisory and RFC 9113 deprecates the scheme: ignored
    }

    private void onRstStream(uint sid, scope const(ubyte)[] payload) nothrow
    {
        if (sid == 0)
            return connectionError(H2Error.protocol);
        if (payload.length != 4)
            return connectionError(H2Error.frameSize);
        auto s = find(sid);
        if (s is null)
        {
            if (sid > lastPeerStream)
                return connectionError(H2Error.protocol); // idle stream
            return;
        }
        if (!s.endSent)
            flood += 2; // reset before the response: the cost of "rapid reset" attacks
        closeStream(s, 2);
    }

    private void onSettings(ubyte flags, uint sid, scope const(ubyte)[] payload) nothrow
    {
        if (sid != 0)
            return connectionError(H2Error.protocol);
        if (flags & flagAck)
        {
            if (payload.length)
                return connectionError(H2Error.frameSize);
            settingsAcked = true;
            return;
        }
        if (payload.length % 6)
            return connectionError(H2Error.frameSize);
        flood++;
        foreach (i; 0 .. payload.length / 6)
            if (auto e = applySetting(payload[i * 6 .. i * 6 + 6]))
                return connectionError(e);
        frameHeader(0, FrameType.settings, flagAck, 0);
    }

    private H2Error applySetting(scope const(ubyte)[] kv) nothrow
    {
        immutable id = cast(ushort)((kv[0] << 8) | kv[1]);
        immutable v = readU32(kv[2 .. 6]);
        switch (id)
        {
            case settingEnablePush:
            case settingEnableConnectProtocol: // a client's value means nothing to a server, but it must be 0 or 1
                if (v > 1)
                    return H2Error.protocol;
                break;
            case settingInitialWindowSize:
                if (v > maxWindow)
                    return H2Error.flowControl;
                immutable delta = cast(long) v - peerInitialWindow;
                peerInitialWindow = v;
                foreach (s; streams[])
                {
                    s.sendWindow += delta;
                    if (s.sendWindow > maxWindow)
                        return H2Error.flowControl;
                }
                break;
            case settingMaxFrameSize:
                if (v < defaultFrameSize || v > (1 << 24) - 1)
                    return H2Error.protocol;
                peerMaxFrame = v;
                break;
            default:
                // HEADER_TABLE_SIZE: our encoder never uses the dynamic table, so any size fits.
                // MAX_CONCURRENT_STREAMS, MAX_HEADER_LIST_SIZE: advisory for a server. Unknown: ignored.
                break;
        }
        return H2Error.noError;
    }

    private void onPing(ubyte flags, uint sid, scope const(ubyte)[] payload) nothrow
    {
        if (sid != 0)
            return connectionError(H2Error.protocol);
        if (payload.length != 8)
            return connectionError(H2Error.frameSize);
        if (flags & flagAck)
            return;
        flood++;
        frameHeader(8, FrameType.ping, flagAck, 0);
        outbox.put(cast(const(char)[]) payload);
    }

    private void onGoAway(uint sid, scope const(ubyte)[] payload) nothrow
    {
        if (sid != 0)
            return connectionError(H2Error.protocol);
        if (payload.length < 8)
            return connectionError(H2Error.frameSize);
        goAwayReceived = true;
    }

    private void onWindowUpdate(uint sid, scope const(ubyte)[] payload) nothrow
    {
        if (payload.length != 4)
            return connectionError(H2Error.frameSize);
        immutable inc = readU32(payload) & 0x7fff_ffff;
        if (sid == 0)
        {
            if (inc == 0)
                return connectionError(H2Error.protocol);
            connSendWindow += inc;
            if (connSendWindow > maxWindow)
                return connectionError(H2Error.flowControl);
            return;
        }
        auto s = find(sid);
        if (s is null)
        {
            if (sid > lastPeerStream)
                return connectionError(H2Error.protocol); // idle stream
            return; // closed: frames in flight are expected
        }
        if (inc == 0)
            return resetStream(s, H2Error.protocol);
        s.sendWindow += inc;
        if (s.sendWindow > maxWindow)
            return resetStream(s, H2Error.flowControl);
    }

    // ================================================================ header blocks

    private void headerBlockDone(uint sid) nothrow
    {
        immutable endStream = (hblockFlags & flagEndStream) != 0;
        auto block = cast(const(ubyte)[]) hblock.data;
        auto s = find(sid);
        if (s !is null)
        {
            // a second HEADERS on a live stream: trailers, which must end the stream
            if (s.state != StreamState.open)
            {
                if (!decodeDiscard(block))
                    return;
                return resetStream(s, H2Error.streamClosed);
            }
            if (!decodeInto(s, block, true))
                return;
            if (!endStream || s.malformed || hblockSelfDep)
                return resetStream(s, H2Error.protocol);
            return endOfRequest(s);
        }
        if (sid <= lastPeerStream)
        {
            // an old stream: closed (STREAM_CLOSED) or never opened, which breaks the
            // "identifiers only grow" rule (PROTOCOL_ERROR)
            return connectionError(recentlyClosed(sid) ? H2Error.streamClosed : H2Error.protocol);
        }
        if ((sid & 1) == 0)
            return connectionError(H2Error.protocol); // clients open odd streams
        lastPeerStream = sid;
        if (goAwaySent)
        {
            decodeDiscard(block); // past our GOAWAY: ignored, but the HPACK table must follow
            return;
        }
        if (streams.length >= cfg.maxConcurrentStreams)
        {
            if (decodeDiscard(block))
                sendRst(sid, H2Error.refusedStream);
            return;
        }
        s = newStream(sid);
        s.state = endStream ? StreamState.halfClosedRemote : StreamState.open;
        if (!decodeInto(s, block, false))
            return;
        s.gotHeaders = true;
        if (hblockSelfDep || s.malformed)
            return resetStream(s, H2Error.protocol);
        if (!checkPseudo(s))
            return resetStream(s, H2Error.protocol);
        if (s.earlyStatus)
            return answerEarly(s, s.earlyStatus);
        if (s.tunnel)
            return finishRequest(s); // runs now: its "body" is the tunnel, which lasts as long as the WebSocket
        if (s.contentLength > 0 && s.contentLength > cfg.limits.maxBodyBytes)
            return answerEarly(s, 413);
        if (endStream)
            return endOfRequest(s);
        // the client may be waiting for 100 Continue before sending the body
        const(char)[] expect;
        foreach (i; 0 .. s.fieldCount)
            if (fieldName(s, i) == "expect")
                expect = fieldValue(s, i);
        if (equalsIgnoreCase(expect, "100-continue"))
        {
            hpackOut.clear();
            encodeStatus(hpackOut, 100);
            frameHeader(hpackOut.length, FrameType.headers, flagEndHeaders, s.id);
            outbox.put(hpackOut.data);
        }
    }

    /// Decodes a block whose stream is not processed. Returns false after a connection error.
    private bool decodeDiscard(scope const(ubyte)[] block) nothrow
    {
        if (hpack.decode(block, (scope n, scope v, bool sens) {}) != HpackError.none)
        {
            connectionError(H2Error.compression);
            return false;
        }
        return true;
    }

    private bool decodeInto(H2Stream s, scope const(ubyte)[] block, bool trailers) nothrow
    {
        immutable err = hpack.decode(block, (scope n, scope v, bool sens) {
            if (trailers)
                return checkTrailer(s, n, v);
            addField(s, n, v);
        });
        if (err != HpackError.none)
        {
            if (!trailers)
                closeStream(s, 3);
            connectionError(H2Error.compression);
            return false;
        }
        return true;
    }

    private void checkTrailer(H2Stream s, scope const(char)[] n, scope const(char)[] v) nothrow
    {
        if (n.length == 0 || n[0] == ':' || !validName(n) || !validValue(v) || isConnectionSpecific(n))
            s.malformed = true;
        // trailers are accepted and dropped: vela's Request has no place for them
    }

    /// One decoded request field: validates it and stores a copy in the stream.
    private void addField(H2Stream s, scope const(char)[] n, scope const(char)[] v) nothrow
    {
        if (s.malformed)
            return;
        s.listSize += n.length + v.length + 32;
        if (s.listSize > cfg.limits.maxHeadBytes)
        {
            s.tooLarge = true;
            return;
        }
        if (n.length == 0 || !validValue(v))
        {
            s.malformed = true;
            return;
        }
        if (n[0] == ':')
        {
            if (s.sawRegular)
            {
                s.malformed = true; // pseudo-fields come first (§8.3)
                return;
            }
            uint off = cast(uint) s.fieldBytes.length;
            s.fieldBytes.put(v);
            immutable len = cast(uint) v.length;
            if (n == ":method" && !s.sawMethod)
            {
                s.sawMethod = true;
                s.pseudo[0] = off;
                s.pseudo[1] = len;
            }
            else if (n == ":path" && !s.sawPath)
            {
                s.sawPath = true;
                s.pseudo[2] = off;
                s.pseudo[3] = len;
            }
            else if (n == ":scheme" && !s.sawScheme)
            {
                s.sawScheme = true;
                s.scheme[0] = off;
                s.scheme[1] = len;
            }
            else if (n == ":authority" && !s.sawAuthority)
            {
                s.sawAuthority = true;
                s.authority[0] = off;
                s.authority[1] = len;
            }
            else if (n == ":protocol" && !s.sawProtocol && cfg.enableConnectProtocol)
            {
                // only after we announced SETTINGS_ENABLE_CONNECT_PROTOCOL (RFC 8441 §3); otherwise an unknown field
                s.sawProtocol = true;
                s.protocol[0] = off;
                s.protocol[1] = len;
            }
            else
                s.malformed = true; // unknown, duplicated or a response pseudo-field
            return;
        }
        s.sawRegular = true;
        if (!validName(n) || isConnectionSpecific(n) || (n == "te" && v != "trailers"))
        {
            s.malformed = true;
            return;
        }
        if (n == "content-length")
        {
            long cl = 0;
            if (v.length == 0 || v.length > 18)
            {
                s.malformed = true;
                return;
            }
            foreach (c; v)
            {
                if (c < '0' || c > '9')
                {
                    s.malformed = true;
                    return;
                }
                cl = cl * 10 + (c - '0');
            }
            if (s.contentLength >= 0 && s.contentLength != cl)
            {
                s.malformed = true;
                return;
            }
            s.contentLength = cl;
        }
        if (n == "cookie")
            s.cookieCrumbs = true;
        if (s.fieldCount == s.fieldRefs.length)
        {
            s.tooLarge = true;
            return;
        }
        immutable off = cast(uint) s.fieldBytes.length;
        s.fieldBytes.put(n);
        s.fieldBytes.put(v);
        s.setRef(s.fieldCount++, off, n.length, off + n.length, v.length);
    }

    /// Required pseudo-fields (§8.3.1) and what vela can serve. Sets `earlyStatus` for
    /// requests that are well formed but not acceptable (431, 414, 400, 501).
    private bool checkPseudo(H2Stream s) nothrow
    {
        if (!s.sawMethod)
            return false; // checked first: the offsets below are only meaningful once it was seen
        auto method = s.fieldBytes.data[s.pseudo[0] .. s.pseudo[0] + s.pseudo[1]];
        if (method == "CONNECT" && !s.sawProtocol)
        {
            if (s.sawPath || s.sawScheme || !s.sawAuthority)
                return false;
            s.earlyStatus = 501;
            return true;
        }
        if (s.sawProtocol)
        {
            // extended CONNECT (RFC 8441 §4): :scheme, :path and :authority are all required
            if (method != "CONNECT" || !s.sawAuthority)
                return false;
            s.tunnel = true;
            if (s.fieldBytes.data[s.protocol[0] .. s.protocol[0] + s.protocol[1]] != "websocket")
                s.earlyStatus = 501; // a protocol vela does not speak (webtransport, connect-udp...)
        }
        if (!s.sawScheme || !s.sawPath || s.pseudo[3] == 0)
            return false;
        auto path = s.fieldBytes.data[s.pseudo[2] .. s.pseudo[2] + s.pseudo[3]];
        if (s.tooLarge)
            s.earlyStatus = 431;
        else if (path.length > cfg.limits.maxTargetBytes)
            s.earlyStatus = 414;
        else if (path[0] != '/' && !(method == "OPTIONS" && path == "*"))
            s.earlyStatus = 400;
        else if (!s.tunnel && parseMethod(method) == Method.unknown)
            s.earlyStatus = 501;
        else
            foreach (char c; path)
                if (c <= ' ' || c == 0x7f)
                {
                    s.earlyStatus = 400;
                    break;
                }
        return true;
    }

    private const(char)[] fieldName(H2Stream s, size_t i) const nothrow @nogc
    {
        auto r = s.fieldRefs[i];
        return s.fieldBytes.data[r[0] .. r[0] + r[1]];
    }

    private const(char)[] fieldValue(H2Stream s, size_t i) const nothrow @nogc
    {
        auto r = s.fieldRefs[i];
        return s.fieldBytes.data[r[2] .. r[2] + r[3]];
    }

    // ================================================================ requests

    /// END_STREAM on a stream that was open.
    private void endOfRequest(H2Stream s) nothrow
    {
        if (s.tunnel)
        {
            // the request was handed out with its HEADERS: this is the peer ending the tunnel
            if (s.state == StreamState.halfClosedLocal)
                return closeStream(s, 1);
            s.state = StreamState.halfClosedRemote;
            if (s.responding && s.endSent)
                return closeStream(s, 1);
            return queueInput(s);
        }
        if (s.contentLength >= 0 && s.received != s.contentLength)
            return resetStream(s, H2Error.protocol);
        if (s.state == StreamState.open)
            s.state = StreamState.halfClosedRemote;
        if (s.responding)
        {
            // an early answer went out before the client finished: the exchange is over
            if (s.endSent)
                closeStream(s, 1);
            return;
        }
        finishRequest(s);
    }

    /// Builds `s.req` from the stored fields and queues the stream for the engine.
    private void finishRequest(H2Stream s) nothrow
    {
        if (s.earlyStatus || s.tooLarge)
            return answerEarly(s, s.earlyStatus ? s.earlyStatus : 431);
        // cookies may arrive split into several fields (§8.2.3): one field for the application
        if (s.cookieCrumbs)
            mergeCookies(s);
        auto bytes = s.fieldBytes.data;
        size_t n = 0;
        bool haveHost = false;
        foreach (i; 0 .. s.fieldCount)
        {
            auto r = s.fieldRefs[i];
            if (r[1] == 0)
                continue; // a merged cookie crumb
            auto name = bytes[r[0] .. r[0] + r[1]];
            haveHost |= equalsIgnoreCase(name, "host");
            s.store[n++] = HeaderField(name, bytes[r[2] .. r[2] + r[3]]);
        }
        if (!haveHost && s.sawAuthority)
            s.store[n++] = HeaderField("host", bytes[s.authority[0] .. s.authority[0] + s.authority[1]]);
        Request r;
        r.protocol = Protocol.http2;
        if (s.tunnel)
        {
            r.method = Method.GET; // routes to the `ws!` route of the path, like an HTTP/1.1 upgrade
            r.connectProtocol = bytes[s.protocol[0] .. s.protocol[0] + s.protocol[1]];
        }
        else
            r.method = parseMethod(bytes[s.pseudo[0] .. s.pseudo[0] + s.pseudo[1]]);
        r.target = bytes[s.pseudo[2] .. s.pseudo[2] + s.pseudo[3]];
        splitTarget(r.target, r.path, r.query);
        r.headers = s.store[0 .. n];
        r.body = cast(const(ubyte)[]) s.body.data;
        r.keepAlive = true;
        s.req = r;
        s.queued = true;
        readyQ.push(s);
    }

    private void mergeCookies(H2Stream s) nothrow
    {
        size_t count = 0, first = size_t.max;
        foreach (i; 0 .. s.fieldCount)
            if (fieldName(s, i) == "cookie")
            {
                count++;
                if (first == size_t.max)
                    first = i;
            }
        if (count < 2)
            return;
        immutable off = cast(uint) s.fieldBytes.length;
        bool firstOne = true;
        foreach (i; 0 .. s.fieldCount)
        {
            if (fieldName(s, i) != "cookie")
                continue;
            auto r = s.fieldRefs[i];
            if (!firstOne)
                s.fieldBytes.put("; ");
            firstOne = false;
            // copy through indices: put may move the buffer
            foreach (k; 0 .. r[3])
                s.fieldBytes.put(s.fieldBytes.data[r[2] + k]);
            if (i != first)
                s.fieldRefs[i][1] = 0;
        }
        s.fieldRefs[first][2] = off;
        s.fieldRefs[first][3] = cast(uint)(s.fieldBytes.length - off);
    }

    /// The session answers by itself (limits, malformed-but-answerable requests, timeouts).
    private void answerEarly(H2Stream s, int status) nothrow
    {
        s.earlyStatus = status;
        if (s.responding)
            return;
        s.task = null;
        s.response.clear();
        s.sendPos = s.sendEnd = 0;
        s.bodyDone = true;
        const ResponseHead head = ResponseHead(status, null, null, 0);
        sendHead(s, head, true);
    }

    // ================================================================ responses

    /// Encodes `head` as HEADERS (+ CONTINUATION). With `endStream` the response has no body and the stream ends here;
    /// otherwise the stream joins the DATA round robin (`s.sendPos`..`s.sendEnd` of `s.response` is its body so far).
    private void sendHead(H2Stream s, ref const ResponseHead head, bool endStream) nothrow
    {
        s.responding = true;
        hpackOut.clear();
        encodeStatus(hpackOut, head.status);
        if (head.contentType.length)
            encodeField(hpackOut, "content-type", head.contentType);
        if (head.contentLength >= 0 && head.status != 204 && head.status != 304)
        {
            char[20] digits = void;
            size_t k = digits.length;
            ulong v = cast(ulong) head.contentLength;
            do
            {
                digits[--k] = cast(char)('0' + v % 10);
                v /= 10;
            }
            while (v);
            encodeField(hpackOut, "content-length", digits[k .. $]);
        }
        foreach (ref h; head.headers)
        {
            if (isHopByHop(h.name) || equalsIgnoreCase(h.name, "content-length") || equalsIgnoreCase(h.name, "content-type"))
                continue;
            encodeField(hpackOut, h.name, h.value,
                equalsIgnoreCase(h.name, "set-cookie") || equalsIgnoreCase(h.name, "authorization"));
        }

        // HEADERS, then CONTINUATIONs if the block exceeds the peer's frame size
        auto block = hpackOut.data;
        size_t chunk = block.length < peerMaxFrame ? block.length : peerMaxFrame;
        ubyte flags = (chunk == block.length ? flagEndHeaders : 0) | (endStream ? flagEndStream : 0);
        frameHeader(chunk, FrameType.headers, flags, s.id);
        outbox.put(block[0 .. chunk]);
        block = block[chunk .. $];
        while (block.length)
        {
            chunk = block.length < peerMaxFrame ? block.length : peerMaxFrame;
            frameHeader(chunk, FrameType.continuation, chunk == block.length ? flagEndHeaders : 0, s.id);
            outbox.put(block[0 .. chunk]);
            block = block[chunk .. $];
        }
        if (endStream)
            endSent(s);
        else
            sending.push(s);
    }

    /// Moves DATA into the output while windows allow and output is below the high-water
    /// mark. Round robin: each pass gives every sending stream at most one frame.
    private void pump() nothrow
    {
        if (fatal)
            return;
        while (sending.length && connSendWindow > 0 && outbox.length - outPos < cfg.outputHighWater)
        {
            bool progress = false;
            size_t i = 0;
            while (i < sending.length && connSendWindow > 0 && outbox.length - outPos < cfg.outputHighWater)
            {
                auto s = sending[i];
                size_t n = s.sendEnd - s.sendPos;
                if (n > peerMaxFrame)
                    n = peerMaxFrame;
                if (n > connSendWindow)
                    n = cast(size_t) connSendWindow;
                if (s.sendWindow <= 0)
                    n = 0;
                else if (n > s.sendWindow)
                    n = cast(size_t) s.sendWindow;
                if (n == 0)
                {
                    i++;
                    continue;
                }
                immutable last = s.bodyDone && s.sendPos + n == s.sendEnd;
                frameHeader(n, FrameType.data, last ? flagEndStream : 0, s.id);
                outbox.put(s.response.data[s.sendPos .. s.sendPos + n]);
                s.sendPos += n;
                s.sendWindow -= n;
                connSendWindow -= n;
                progress = true;
                if (last)
                {
                    sending.removeAt(i); // the last one takes its place: do not advance
                    endSent(s);
                }
                else
                {
                    if (!s.bodyDone && s.sendPos == s.sendEnd)
                    {
                        s.response.clear(); // a streamed body: do not keep what was already sent
                        s.sendPos = s.sendEnd = 0;
                        if (s.tunnel)
                            s.response.shrinkTo(cfg.outputHighWater * 2); // a big message does not stay pinned to it
                    }
                    i++;
                }
            }
            if (!progress)
                break;
        }
    }

    /// END_STREAM went out.
    private void endSent(H2Stream s) nothrow
    {
        s.endSent = true;
        if (s.state == StreamState.halfClosedRemote)
            return closeStream(s, 1);
        if (s.state == StreamState.open && s.tunnelUp)
        {
            // our side of a tunnel ended (the WebSocket closed): the peer's last frames and END_STREAM may still be on
            // their way, so wait for them (`tick` resets the stream if they never come)
            s.state = StreamState.halfClosedLocal;
            return;
        }
        if (s.state == StreamState.open)
        {
            // answered before the client finished sending (413, 431...): stop the upload (§8.1)
            rstFrame(s.id, H2Error.noError);
            closeStream(s, 3);
        }
    }

    // ================================================================ streams

    private H2Stream find(uint id) nothrow @nogc
    {
        foreach (s; streams[])
            if (s.id == id)
                return s;
        return null;
    }

    private H2Stream newStream(uint id) nothrow
    {
        H2Stream s;
        if (spare.length)
            s = spare.pop();
        else
            s = new H2Stream(cfg.maxHeaders);
        s.id = id;
        s.state = StreamState.open;
        s.openedMs = nowMs;
        s.sendWindow = peerInitialWindow;
        s.recvWindow = cfg.initialWindowSize;
        streams.push(s);
        return s;
    }

    /// `how`: 1 = closed normally, 2 = reset by the peer, 3 = reset by us.
    private void closeStream(H2Stream s, ubyte how) nothrow
    {
        if (s.state == StreamState.closed || s.state == StreamState.idle)
            return;
        s.state = StreamState.closed;
        recentId[recentNext] = s.id;
        recentHow[recentNext] = how;
        recentNext = (recentNext + 1) % recentId.length;
        streams.remove(s);
        sending.remove(s);
        if (s.task !is null)
        {
            // the engine still runs a handler for it: it must cancel it, then `detach`
            s.resetByPeer = true;
            zombies++;
            resetQ.push(s);
            return;
        }
        if (!s.queued)
            recycle(s); // a queued one is recycled when popReady skips it
    }

    private void recycle(H2Stream s) nothrow
    {
        if (s.state == StreamState.idle && s.id == 0)
            return; // already back in the pool
        if (s.inputQueued)
            inputQ.remove(s);
        s.reset();
        if (spare.length < 8)
            spare.push(s);
        else
            s.releaseMemory();
    }

    private ubyte recentlyClosed(uint id) const nothrow @nogc
    {
        foreach (i, x; recentId)
            if (x == id)
                return recentHow[i];
        return 0;
    }

    /// Stream error (§5.4.2): RST_STREAM and the stream is gone. If the engine holds it (a handler
    /// is running), it goes to `popReset` to be cancelled.
    private void resetStream(H2Stream s, H2Error code) nothrow
    {
        rstFrame(s.id, code);
        closeStream(s, 3);
    }

    /// Stream error on a stream we hold no state for. RST_STREAM must not be sent for a stream
    /// that was never opened (§6.4): above the last client stream, or even (server-initiated,
    /// and we never initiate). There the error becomes a connection error with the same code.
    private void sendRst(uint sid, H2Error code) nothrow
    {
        if ((sid & 1) == 0 || sid > lastPeerStream)
            return connectionError(code);
        rstFrame(sid, code);
    }

    /// Connection error (§5.4.1): GOAWAY with the code; every stream is gone.
    private void connectionError(H2Error code) nothrow
    {
        if (fatal)
            return;
        goAwayFrame(code);
        fatal = true;
        hblockStream = 0;
        // streams with running handlers are cancelled by the engine when it closes the socket
        while (streams.length)
            closeStream(streams[streams.length - 1], 3);
    }

    // ================================================================ frames out

    private void frameHeader(size_t len, FrameType type, ubyte flags, uint sid) nothrow @nogc
    {
        char[9] h = void;
        h[0] = cast(char)(len >> 16);
        h[1] = cast(char)(len >> 8);
        h[2] = cast(char) len;
        h[3] = cast(char) type;
        h[4] = cast(char) flags;
        h[5] = cast(char)((sid >> 24) & 0x7f);
        h[6] = cast(char)(sid >> 16);
        h[7] = cast(char)(sid >> 8);
        h[8] = cast(char) sid;
        outbox.put(h[]);
    }

    private void putU32(uint v) nothrow @nogc
    {
        char[4] b = void;
        b[0] = cast(char)(v >> 24);
        b[1] = cast(char)(v >> 16);
        b[2] = cast(char)(v >> 8);
        b[3] = cast(char) v;
        outbox.put(b[]);
    }

    private void windowUpdate(uint sid, uint inc) nothrow @nogc
    {
        frameHeader(4, FrameType.windowUpdate, 0, sid);
        putU32(inc & 0x7fff_ffff);
    }

    private void rstFrame(uint sid, H2Error code) nothrow @nogc
    {
        frameHeader(4, FrameType.rstStream, 0, sid);
        putU32(code);
    }

    private void goAwayFrame(H2Error code) nothrow @nogc
    {
        goAwaySent = true;
        lastError = code;
        frameHeader(8, FrameType.goAway, 0, 0);
        putU32(lastPeerStream);
        putU32(code);
    }

}

// ============================================================================= helpers

private uint clampWindow(uint w) pure nothrow @nogc
{
    return w < defaultWindow ? defaultWindow : w > maxWindow ? cast(uint) maxWindow : w;
}

private uint readU32(scope const(ubyte)[] b) pure nothrow @nogc
{
    return (cast(uint) b[0] << 24) | (cast(uint) b[1] << 16) | (cast(uint) b[2] << 8) | b[3];
}

/// Strips padding (PADDED flag). False when the pad length does not fit (PROTOCOL_ERROR).
private bool unpad(ubyte flags, scope const(ubyte)[] payload, out const(ubyte)[] data) pure nothrow @nogc @trusted
{
    // @trusted: `data` is a sub-slice of `payload` that the caller keeps no longer than `payload` (a frame handler's local)
    if (!(flags & flagPadded))
    {
        data = payload;
        return true;
    }
    if (payload.length == 0 || payload[0] >= payload.length)
        return false;
    data = payload[1 .. $ - payload[0]];
    return true;
}

/// The RFC 9113 name of an error code, for logs.
string h2ErrorName(H2Error e) pure nothrow @nogc
{
    static immutable string[14] names = ["NO_ERROR", "PROTOCOL_ERROR", "INTERNAL_ERROR", "FLOW_CONTROL_ERROR",
        "SETTINGS_TIMEOUT", "STREAM_CLOSED", "FRAME_SIZE_ERROR", "REFUSED_STREAM", "CANCEL", "COMPRESSION_ERROR",
        "CONNECT_ERROR", "ENHANCE_YOUR_CALM", "INADEQUATE_SECURITY", "HTTP_1_1_REQUIRED"];
    return e < names.length ? names[e] : "UNKNOWN_ERROR";
}

/// Hop-by-hop fields that HTTP/2 forbids (§8.2.2).
bool isConnectionSpecific(scope const(char)[] name) pure nothrow @nogc
{
    return equalsIgnoreCase(name, "connection") || equalsIgnoreCase(name, "keep-alive")
        || equalsIgnoreCase(name, "proxy-connection") || equalsIgnoreCase(name, "transfer-encoding")
        || equalsIgnoreCase(name, "upgrade");
}

/// Lowercase token characters only (§8.2.1).
private bool validName(scope const(char)[] n) pure nothrow @nogc
{
    foreach (c; n)
        if (c <= 0x20 || (c >= 'A' && c <= 'Z') || c >= 0x7f)
            return false;
    return true;
}

/// No NUL, CR or LF; no leading or trailing whitespace (§8.2.1).
private bool validValue(scope const(char)[] v) pure nothrow @nogc
{
    foreach (c; v)
        if (c == 0 || c == '\r' || c == '\n')
            return false;
    if (v.length && (v[0] == ' ' || v[0] == '\t' || v[$ - 1] == ' ' || v[$ - 1] == '\t'))
        return false;
    return true;
}

/// Growable array of streams that reuses its memory (no GC churn after warm-up).
private struct Vec
{
    private H2Stream[] a;
    private size_t n;

    size_t length() const pure nothrow @nogc => n;
    H2Stream[] opIndex() pure nothrow @nogc return => a[0 .. n];
    ref H2Stream opIndex(size_t i) pure nothrow @nogc return => a[i];

    void push(H2Stream s) nothrow
    {
        if (n == a.length)
            a.length = a.length ? a.length * 2 : 8;
        a[n++] = s;
    }

    H2Stream pop() nothrow @nogc
    {
        auto s = a[--n];
        a[n] = null;
        return s;
    }

    void removeAt(size_t i) nothrow @nogc
    {
        a[i] = a[n - 1];
        a[--n] = null;
    }

    void remove(H2Stream s) nothrow @nogc
    {
        foreach (i; 0 .. n)
            if (a[i] is s)
                return removeAt(i);
    }

    void clear() nothrow @nogc
    {
        a[0 .. n] = null;
        n = 0;
    }
}

/// Whether an HTTP/1.1 request asks to switch to h2c (RFC 7540 §3.2): `Upgrade: h2c`,
/// `Connection` listing both `Upgrade` and `HTTP2-Settings`, and exactly one HTTP2-Settings.
bool wantsH2cUpgrade(ref const Request r, out const(char)[] settings) pure nothrow @nogc
{
    size_t nSettings = 0;
    bool upgrade = false, connUpgrade = false, connSettings = false;
    foreach (ref h; r.headers)
    {
        if (equalsIgnoreCase(h.name, "upgrade"))
        {
            foreach (tok; TokenRange(h.value))
                upgrade |= equalsIgnoreCase(tok, "h2c");
        }
        else if (equalsIgnoreCase(h.name, "connection"))
        {
            foreach (tok; TokenRange(h.value))
            {
                connUpgrade |= equalsIgnoreCase(tok, "upgrade");
                connSettings |= equalsIgnoreCase(tok, "http2-settings");
            }
        }
        else if (equalsIgnoreCase(h.name, "http2-settings"))
        {
            nSettings++;
            settings = h.value;
        }
    }
    return upgrade && connUpgrade && connSettings && nSettings == 1;
}

/// Comma-separated tokens, trimmed.
private struct TokenRange
{
    const(char)[] rest;
    const(char)[] front;
    bool empty;

    this(const(char)[] s) pure nothrow @nogc
    {
        rest = s;
        popFront();
    }

    void popFront() pure nothrow @nogc
    {
        if (rest is null)
        {
            empty = true;
            return;
        }
        size_t i = 0;
        while (i < rest.length && rest[i] != ',')
            i++;
        auto tok = rest[0 .. i];
        rest = i < rest.length ? rest[i + 1 .. $] : null;
        while (tok.length && (tok[0] == ' ' || tok[0] == '\t'))
            tok = tok[1 .. $];
        while (tok.length && (tok[$ - 1] == ' ' || tok[$ - 1] == '\t'))
            tok = tok[0 .. $ - 1];
        front = tok;
    }
}

/// base64url without padding (the HTTP2-Settings header). False on invalid input.
public import vela.http.base64url : decodeBase64Url;
