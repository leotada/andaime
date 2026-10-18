/// WebSocket (RFC 6455) with permessage-deflate (RFC 7692): frames, the opening handshake, and the message layer `WsConn`.
///
/// No I/O here: `WsConn` reads and writes through an `UpgradedConn` (andaime.http.response), which the engine implements on
/// a socket, the WebSocket client on its own connection and `TestClient` in memory. Compression goes through `WsDeflate`,
/// which the engine implements with zlib.
module andaime.http.websocket;

@safe:

import core.time : Duration, MonoTime, seconds;
import andaime.http.types;
import andaime.http.buffer;
import andaime.http.response : UpgradedConn, FillResult;
import andaime.http.sha1;
import andaime.http.utf8 : validUtf8;

// ============================================================ frames

/// Frame opcodes (RFC 6455 §5.2).
enum WsOpcode : ubyte
{
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
}

/// Close codes (RFC 6455 §7.4.1) andaime sends or reports.
enum WsCloseCode : ushort
{
    normal = 1000,
    goingAway = 1001,
    protocolError = 1002,
    unsupportedData = 1003,
    noStatus = 1005,       /// reported only: the close frame had no code
    abnormal = 1006,       /// reported only: the connection ended without a close frame
    invalidData = 1007,
    policyViolation = 1008,
    tooBig = 1009,
    internalError = 1011,
}

/// A parsed frame header.
struct FrameHeader
{
    bool fin;
    bool rsv1, rsv2, rsv3;
    ubyte opcode;
    bool masked;
    ubyte[4] mask;
    ulong length;          /// payload length
    size_t headerLength;   /// bytes before the payload (2 to 14)
}

enum FrameParse : ubyte
{
    ok,
    needMore,
    badLength, /// a 64-bit length with the most significant bit set
}

/// Parses the frame header at the start of `b`.
FrameParse parseFrameHeader(scope const(ubyte)[] b, out FrameHeader h) pure nothrow @nogc
{
    if (b.length < 2)
        return FrameParse.needMore;
    h.fin = (b[0] & 0x80) != 0;
    h.rsv1 = (b[0] & 0x40) != 0;
    h.rsv2 = (b[0] & 0x20) != 0;
    h.rsv3 = (b[0] & 0x10) != 0;
    h.opcode = b[0] & 0x0F;
    h.masked = (b[1] & 0x80) != 0;
    ulong len = b[1] & 0x7F;
    size_t p = 2;
    if (len == 126)
    {
        if (b.length < 4)
            return FrameParse.needMore;
        len = (uint(b[2]) << 8) | b[3];
        p = 4;
    }
    else if (len == 127)
    {
        if (b.length < 10)
            return FrameParse.needMore;
        len = 0;
        foreach (i; 0 .. 8)
            len = (len << 8) | b[2 + i];
        if (len >> 63)
            return FrameParse.badLength;
        p = 10;
    }
    if (h.masked)
    {
        if (b.length < p + 4)
            return FrameParse.needMore;
        h.mask[] = b[p .. p + 4];
        p += 4;
    }
    h.length = len;
    h.headerLength = p;
    return FrameParse.ok;
}

bool isControl(ubyte opcode) pure nothrow @nogc => (opcode & 0x8) != 0;

/// The close code to fail the connection with when frame `h` breaks the protocol, 0 when it is acceptable.
///   `fromClient`: the frame was sent by a client (it must be masked; a server's must not be).
///   `inMessage`: a fragmented data message is in progress (a continuation is expected).
///   `deflate`: permessage-deflate was negotiated (RSV1 marks a compressed message).
ushort frameError(ref const FrameHeader h, bool fromClient, bool inMessage, bool deflate) pure nothrow @nogc
{
    if (h.rsv2 || h.rsv3 || h.masked != fromClient)
        return WsCloseCode.protocolError;
    switch (h.opcode)
    {
        case WsOpcode.continuation:
            return !inMessage || h.rsv1 ? WsCloseCode.protocolError : 0;
        case WsOpcode.text:
        case WsOpcode.binary:
            return inMessage || (h.rsv1 && !deflate) ? WsCloseCode.protocolError : 0;
        case WsOpcode.close:
        case WsOpcode.ping:
        case WsOpcode.pong:
            return !h.fin || h.length > 125 || h.rsv1 ? WsCloseCode.protocolError : 0;
        default:
            return WsCloseCode.protocolError;
    }
}

/// Whether `code` may appear in a close frame (RFC 6455 §7.4).
bool validCloseCode(uint code) pure nothrow @nogc
{
    return (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1011) || (code >= 3000 && code <= 4999);
}

/// XORs `data` with the masking key, `offset` being the position of `data[0]` in the payload (RFC 6455 §5.3). Masking
/// and unmasking are the same operation.
void applyMask(ubyte[] data, ref const ubyte[4] key, size_t offset) pure nothrow @nogc
{
    union Word
    {
        ulong v;
        ubyte[8] b;
    }

    Word k;
    foreach (i; 0 .. 8)
        k.b[i] = key[(offset + i) & 3];
    size_t i;
    for (; i + 8 <= data.length; i += 8)
    {
        Word w;
        w.b[] = data[i .. i + 8];
        w.v ^= k.v;
        data[i .. i + 8] = w.b[];
    }
    for (; i < data.length; i++)
        data[i] ^= k.b[i & 7];
}

/// Appends one frame to `o`. A client passes a 4-byte `maskKey` (the payload is masked in the copy); a server passes null.
void encodeFrame(ref ByteBuffer o, ubyte opcode, bool fin, bool rsv1, scope const(ubyte)[] payload,
    scope const(ubyte)[] maskKey = null) nothrow @nogc
{
    immutable size_t n = payload.length;
    o.put(cast(char)((fin ? 0x80 : 0) | (rsv1 ? 0x40 : 0) | opcode));
    immutable ubyte m = maskKey.length ? 0x80 : 0;
    if (n < 126)
        o.put(cast(char)(m | n));
    else if (n <= 0xFFFF)
    {
        o.put(cast(char)(m | 126));
        o.put(cast(char)(n >> 8));
        o.put(cast(char)(n & 0xFF));
    }
    else
    {
        o.put(cast(char)(m | 127));
        foreach (i; 0 .. 8)
            o.put(cast(char)((cast(ulong) n >> (56 - 8 * i)) & 0xFF));
    }
    if (!maskKey.length)
    {
        o.put(cast(const(char)[]) payload);
        return;
    }
    assert(maskKey.length == 4, "andaime: a masking key has 4 bytes");
    o.put(cast(const(char)[]) maskKey);
    auto dst = cast(ubyte[]) o.writable(n);
    dst[] = payload[];
    ubyte[4] key = maskKey[0 .. 4];
    applyMask(dst, key, 0);
    o.commit(n);
}

// ============================================================ handshake

/// The value both sides append to the key (RFC 6455 §1.3).
enum wsGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// `Sec-WebSocket-Accept` for a `Sec-WebSocket-Key`: base64(SHA-1(key ~ GUID)).
char[28] acceptKey(scope const(char)[] key) pure nothrow @nogc
{
    Sha1 h;
    h.put(key);
    h.put(wsGuid);
    immutable digest = h.finish();
    char[28] o;
    base64Encode(digest[], o[]);
    return o;
}

/// Whether `key` looks like base64 of 16 bytes (24 characters ending in "==").
bool validKey(scope const(char)[] key) pure nothrow @nogc
{
    if (key.length != 24 || key[22] != '=' || key[23] != '=')
        return false;
    foreach (c; key[0 .. 22])
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '/'))
            return false;
    return true;
}

/// Whether the comma-separated header value `list` contains `token` (case-insensitive, spaces around it ignored).
bool hasToken(scope const(char)[] list, scope const(char)[] token) pure nothrow @nogc
{
    while (list.length)
    {
        size_t i;
        while (i < list.length && list[i] != ',')
            i++;
        if (equalsIgnoreCase(trim(list[0 .. i]), token))
            return true;
        list = i < list.length ? list[i + 1 .. $] : null;
    }
    return false;
}

private inout(char)[] trim(return scope inout(char)[] s) pure nothrow @nogc
{
    while (s.length && (s[0] == ' ' || s[0] == '\t'))
        s = s[1 .. $];
    while (s.length && (s[$ - 1] == ' ' || s[$ - 1] == '\t'))
        s = s[0 .. $ - 1];
    return s;
}

/// The outcome of checking an upgrade request.
enum WsHandshake : ubyte
{
    ok,
    notUpgrade, /// not a WebSocket upgrade at all (or not HTTP/1.1): answer 426
    badVersion, /// `Sec-WebSocket-Version` is not 13: answer 426 with `Sec-WebSocket-Version: 13`
    badKey,     /// `Sec-WebSocket-Key` missing, repeated or malformed: answer 400
}

/// Checks an opening handshake and returns its key: RFC 6455 §4.2.1 on HTTP/1.1, RFC 8441 §5 on HTTP/2 (an extended
/// CONNECT, which has no key: `key` stays null).
WsHandshake checkUpgradeRequest(ref const Request r, out const(char)[] key) pure nothrow @nogc
{
    if (r.method != Method.GET)
        return WsHandshake.notUpgrade;
    if (r.protocol == Protocol.http2)
    {
        if (r.connectProtocol != "websocket")
            return WsHandshake.notUpgrade;
        size_t n;
        const(char)[] v;
        foreach (ref h; r.headers)
            if (equalsIgnoreCase(h.name, "sec-websocket-version"))
            {
                n++;
                v = trim(h.value);
            }
        return n == 1 && v == "13" ? WsHandshake.ok : WsHandshake.badVersion;
    }
    if (r.protocol != Protocol.http1 || !r.http11)
        return WsHandshake.notUpgrade;
    bool upgrade, connection;
    size_t versions, keys;
    const(char)[] version_;
    foreach (ref h; r.headers)
    {
        if (equalsIgnoreCase(h.name, "upgrade"))
            upgrade |= hasToken(h.value, "websocket");
        else if (equalsIgnoreCase(h.name, "connection"))
            connection |= hasToken(h.value, "upgrade");
        else if (equalsIgnoreCase(h.name, "sec-websocket-version"))
        {
            versions++;
            version_ = trim(h.value);
        }
        else if (equalsIgnoreCase(h.name, "sec-websocket-key"))
        {
            keys++;
            key = trim(h.value);
        }
    }
    if (!upgrade || !connection)
        return WsHandshake.notUpgrade;
    if (versions != 1 || version_ != "13")
        return WsHandshake.badVersion;
    if (keys != 1 || !validKey(key))
        return WsHandshake.badKey;
    return WsHandshake.ok;
}

// ============================================================ permessage-deflate

/// The negotiated permessage-deflate parameters (RFC 7692 §7.1).
struct DeflateParams
{
    bool serverNoContextTakeover;
    bool clientNoContextTakeover;
    ubyte serverMaxWindowBits = 15;
    ubyte clientMaxWindowBits = 15;
    bool clientMaxWindowBitsSent; /// the offer named client_max_window_bits (with or without a value)
}

/// Parses one extension `permessage-deflate; param; param=value`. False when it is another extension, or a parameter is
/// unknown, repeated or out of range (that offer is then declined).
bool parseDeflate(scope const(char)[] ext, out DeflateParams p) pure nothrow @nogc
{
    size_t i;
    while (i < ext.length && ext[i] != ';')
        i++;
    if (!equalsIgnoreCase(trim(ext[0 .. i]), "permessage-deflate"))
        return false;
    bool seenSnc, seenCnc, seenSmw, seenCmw;
    auto rest = i < ext.length ? ext[i + 1 .. $] : null;
    while (rest.length)
    {
        size_t j;
        while (j < rest.length && rest[j] != ';')
            j++;
        auto param = trim(rest[0 .. j]);
        rest = j < rest.length ? rest[j + 1 .. $] : null;
        const(char)[] name = param, value;
        bool hasValue;
        foreach (k, c; param)
            if (c == '=')
            {
                name = trim(param[0 .. k]);
                value = trim(param[k + 1 .. $]);
                hasValue = true;
                break;
            }
        if (value.length >= 2 && value[0] == '"' && value[$ - 1] == '"')
            value = value[1 .. $ - 1];
        if (equalsIgnoreCase(name, "server_no_context_takeover") && !hasValue && !seenSnc)
            seenSnc = p.serverNoContextTakeover = true;
        else if (equalsIgnoreCase(name, "client_no_context_takeover") && !hasValue && !seenCnc)
            seenCnc = p.clientNoContextTakeover = true;
        else if (equalsIgnoreCase(name, "server_max_window_bits") && hasValue && !seenSmw)
        {
            seenSmw = true;
            if (!windowBits(value, p.serverMaxWindowBits))
                return false;
        }
        else if (equalsIgnoreCase(name, "client_max_window_bits") && !seenCmw)
        {
            seenCmw = p.clientMaxWindowBitsSent = true;
            if (hasValue && !windowBits(value, p.clientMaxWindowBits))
                return false;
        }
        else
            return false;
    }
    return true;
}

private bool windowBits(scope const(char)[] v, out ubyte bits) pure nothrow @nogc
{
    if (v.length == 1 && v[0] >= '8' && v[0] <= '9')
        bits = cast(ubyte)(v[0] - '0');
    else if (v.length == 2 && v[0] == '1' && v[1] >= '0' && v[1] <= '5')
        bits = cast(ubyte)(10 + v[1] - '0');
    else
        return false;
    return true;
}

/// Server side: picks the first acceptable permessage-deflate offer among the request's `Sec-WebSocket-Extensions`.
bool negotiateDeflate(ref const Request r, out DeflateParams p) pure nothrow @nogc
{
    foreach (ref h; r.headers)
    {
        if (!equalsIgnoreCase(h.name, "sec-websocket-extensions"))
            continue;
        const(char)[] list = h.value;
        while (list.length)
        {
            size_t i;
            bool quoted;
            while (i < list.length && (list[i] != ',' || quoted))
            {
                if (list[i] == '"')
                    quoted = !quoted;
                i++;
            }
            if (parseDeflate(list[0 .. i], p))
                return true;
            list = i < list.length ? list[i + 1 .. $] : null;
        }
    }
    p = DeflateParams.init;
    return false;
}

/// The server's `Sec-WebSocket-Extensions` answer for the accepted parameters. The server keeps its own context unless
/// asked not to; it does not restrict the client's window (an inflater with 15 bits reads any window).
void writeDeflateResponse(ref ByteBuffer o, ref const DeflateParams p) nothrow @nogc
{
    o.put("permessage-deflate");
    if (p.serverNoContextTakeover)
        o.put("; server_no_context_takeover");
    if (p.clientNoContextTakeover)
        o.put("; client_no_context_takeover");
    if (p.serverMaxWindowBits != 15)
    {
        o.put("; server_max_window_bits=");
        o.putUint(p.serverMaxWindowBits);
    }
}

/// Result of `WsDeflate.decompress`.
enum InflateResult : ubyte
{
    ok,
    tooBig,  /// the message inflates past the limit
    error,   /// not a valid deflate stream
}

/// One connection's permessage-deflate state, provided by the engine (zlib). Compressing and decompressing are
/// synchronous: they never suspend the fiber.
interface WsDeflate
{
@safe:
    /// Appends the compressed form of one whole message to `o`, without the trailing `00 00 FF FF` (RFC 7692 §7.2.1).
    /// False when this side may not compress (an 8-bit window zlib cannot produce) or zlib failed: send it uncompressed.
    bool compress(scope const(ubyte)[] message, ref ByteBuffer o);

    /// Appends the inflated payload of one compressed message to `o`, at most `limit` bytes.
    InflateResult decompress(scope const(ubyte)[] payload, ref ByteBuffer o, size_t limit);

    /// Frees the zlib state. The object is not used afterwards.
    void release();
}

/// Creates the deflate state of one connection: `windowBits` and `noContextTakeover` describe this side's compressor.
/// Returns null when compression is unavailable (zlib could not be loaded).
alias WsDeflateFactory = WsDeflate delegate(int windowBits, bool noContextTakeover) @safe;

// ============================================================ messages

/// Thrown by `WsConn.send` (and friends) when the connection is closed, and by the transport when another fiber writes to
/// a connection that is gone. The fiber that owns the connection gets `RequestCancelled` instead.
final class WsClosed : Exception
{
    this(string msg = "andaime: the WebSocket is closed") pure nothrow @safe
    {
        super(msg);
    }
}

enum WsKind : ubyte
{
    text,
    binary,
    close,
}

/// One message. `data` is a view into the connection's buffer, valid until the next `receive`: copy it (`.idup`) to keep it.
struct WsMessage
{
    WsKind kind;
    const(ubyte)[] data;   /// the payload; for a close, the reason
    ushort closeCode;      /// close only: the peer's code, 1005 when it sent none, 1006 when the connection just ended

    /// The payload as text (valid UTF-8 for a text message, which andaime checks).
    const(char)[] text() const pure nothrow @nogc => cast(const(char)[]) data;

    bool isText() const pure nothrow @nogc => kind == WsKind.text;
    bool isBinary() const pure nothrow @nogc => kind == WsKind.binary;
    bool isClose() const pure nothrow @nogc => kind == WsKind.close;
}

/// Limits and timing of one connection.
struct WsOptions
{
    /// Largest message accepted (after decompression); a larger one closes the connection with 1009.
    size_t maxMessageBytes = 1 << 20;
    /// While `receive` waits, a ping is sent after this long without input, and the connection is dropped (1006) after
    /// as long again. `Duration.zero` disables both.
    Duration pingInterval = 30.seconds;
    /// How long to wait for the peer's answer to our close frame.
    Duration closeTimeout = 1.seconds;
}

/// A WebSocket connection: the server hands one to the `WebSocket` body, `wsConnect` returns one to a client.
///
///     foreach (msg; ws)            // every text or binary message until the peer closes
///         ws.send(msg.text);
///
/// Pings are answered, the close handshake and the protocol's checks (masking, fragments, UTF-8, sizes) are done for
/// you. Receiving belongs to the fiber that owns the connection; `send`, `sendBinary`, `ping` and `close` may be called
/// from any fiber of the same worker (a chat room broadcasting, say).
final class WsConn
{
    private enum State : ubyte { open, closeSent, closed }

    private UpgradedConn io;
    private bool client;
    private WsOptions opts;
    private WsDeflate deflater;
    private bool deflateIn;           // the peer may compress (RSV1)
    private ByteBuffer msg, inflated, frame, scratch;
    private State state;
    private bool inFrame, inMessage, msgCompressed;
    private FrameHeader fh;
    private ulong left;
    private size_t maskPos;
    private ubyte msgOp;
    private ushort code_;
    private ubyte[123] reason_;
    private size_t reasonLen;
    private MonoTime lastInput, pingSentAt, closeSentAt;
    private bool pingOutstanding;
    private ulong rng;
    private WsMessage cur;
    private bool primed;

    /// Messages under this size are sent uncompressed (deflate costs more than it saves).
    enum compressMinBytes = 64;

    /// Prepares the object for a new connection (one object per fiber is reused). `deflate` is null without compression;
    /// `seed` feeds a client's masking keys.
    void reset(UpgradedConn io, bool client, WsOptions opts, WsDeflate deflate = null, ulong seed = 0) nothrow
    {
        this.io = io;
        this.client = client;
        this.opts = opts;
        deflater = deflate;
        deflateIn = deflate !is null;
        enum keep = 64 << 10;
        msg.clear();
        msg.shrinkTo(keep);
        inflated.clear();
        inflated.shrinkTo(keep);
        frame.clear();
        frame.shrinkTo(keep);
        scratch.clear();
        scratch.shrinkTo(keep);
        state = State.open;
        inFrame = inMessage = msgCompressed = false;
        left = maskPos = 0;
        code_ = 0;
        reasonLen = 0;
        lastInput = MonoTime.currTime;
        pingOutstanding = false;
        rng = seed | 1;
        cur = WsMessage.init;
        primed = false;
    }

    /// True until a close frame was sent or received, or the connection ended.
    bool isOpen() const pure nothrow @nogc => state == State.open;

    /// The close code once the connection is closing or closed (see `WsMessage.closeCode`), 0 before.
    ushort closeCode() const pure nothrow @nogc => code_;

    /// Waits for the next text or binary message. Returns a close message (`isClose`) once the connection ends, and
    /// again on every later call.
    WsMessage receive()
    {
        WsMessage m;
        receiveUntil(m, MonoTime.max);
        return m;
    }

    /// Like `receive`, waiting at most `timeout`: false when nothing came in time (pings still go out meanwhile).
    bool tryReceive(out WsMessage m, Duration timeout)
    {
        return receiveUntil(m, MonoTime.currTime + timeout);
    }

    /// Sends a text message.
    void send(scope const(char)[] text)
    {
        sendMessage(WsOpcode.text, cast(const(ubyte)[]) text);
    }

    /// Sends a binary message.
    void sendBinary(scope const(ubyte)[] data)
    {
        sendMessage(WsOpcode.binary, data);
    }

    /// Sends a ping (at most 125 bytes of payload). The pong is consumed by `receive`.
    void ping(scope const(ubyte)[] payload = null)
    {
        if (state != State.open)
            throw new WsClosed;
        sendControl(WsOpcode.ping, payload.length > 125 ? payload[0 .. 125] : payload);
    }

    /// Starts the close handshake with `code` (1000-1003, 1007-1011, 3000-4999) and a short reason (cut at 123 bytes).
    /// Returns at once: the owner's `receive` then returns the close message when the peer answers. Does nothing if the
    /// connection is already closing.
    void close(ushort code = WsCloseCode.normal, scope const(char)[] reason = null)
    {
        if (state != State.open)
            return;
        if (!validCloseCode(code))
            throw new Exception("andaime: invalid WebSocket close code");
        sendClose(code, cast(const(ubyte)[]) reason);
    }

    /// Ends the connection: closes with 1000 if it is still open, waits up to `closeTimeout` for the peer's close frame,
    /// then closes the socket. For the owner only; the server calls it when the handler returns.
    void disconnect()
    {
        scope (exit)
            abort();
        if (state == State.open)
            sendClose(WsCloseCode.normal, null);
        if (state == State.closeSent)
        {
            WsMessage m;
            receiveUntil(m, closeSentAt + opts.closeTimeout);
        }
    }

    /// Ends the connection right away, without waiting for a close handshake (a close frame already sent still goes
    /// out). For the owner only. Idempotent.
    void abort()
    {
        if (state != State.closed)
        {
            state = State.closed;
            if (!code_)
                code_ = WsCloseCode.abnormal;
        }
        if (io !is null)
            io.close();
        if (deflater !is null)
        {
            deflater.release();
            deflater = null;
        }
    }

    // ---- input range, for `foreach (msg; ws)`: every message until the close

    bool empty()
    {
        prime();
        return cur.kind == WsKind.close;
    }

    WsMessage front()
    {
        prime();
        return cur;
    }

    void popFront()
    {
        prime();
        primed = false;
    }

    private void prime()
    {
        if (!primed)
        {
            cur = receive();
            primed = true;
        }
    }

    // ---- receiving

    private WsMessage closeMessage() const pure nothrow @nogc
    {
        return WsMessage(WsKind.close, reason_[0 .. reasonLen], code_ ? code_ : WsCloseCode.abnormal);
    }

    /// Receives until a message, the close, or `deadline` (false).
    private bool receiveUntil(out WsMessage m, MonoTime deadline)
    {
        for (;;)
        {
            if (state == State.closed)
            {
                m = closeMessage();
                return true;
            }
            if (readMessage(m))
                return true;
            if (state == State.closed)
                continue;
            auto now = MonoTime.currTime;
            MonoTime until = deadline;
            if (state == State.closeSent)
                until = earlier(until, closeSentAt + opts.closeTimeout);
            else if (opts.pingInterval > Duration.zero)
                until = earlier(until, (pingOutstanding ? pingSentAt : lastInput) + opts.pingInterval);
            int ms = -1;
            if (until != MonoTime.max)
            {
                immutable left = (until - now).total!"msecs";
                ms = left <= 0 ? 0 : left > int.max ? int.max : cast(int) left + 1;
            }
            final switch (io.fill(ms))
            {
                case FillResult.data:
                    lastInput = MonoTime.currTime;
                    pingOutstanding = false;
                    break;
                case FillResult.eof:
                    state = State.closed; // ended without (an answer to) a close frame
                    code_ = WsCloseCode.abnormal;
                    reasonLen = 0;
                    break;
                case FillResult.stopping:
                    if (state == State.open)
                        sendClose(WsCloseCode.goingAway, null);
                    break;
                case FillResult.timeout:
                    now = MonoTime.currTime;
                    if (state == State.closeSent && now >= closeSentAt + opts.closeTimeout)
                    {
                        state = State.closed; // no answer: give up on the handshake
                        code_ = WsCloseCode.abnormal;
                    }
                    else if (state == State.open && opts.pingInterval > Duration.zero)
                    {
                        if (pingOutstanding && now >= pingSentAt + opts.pingInterval)
                            abort(); // nothing for two intervals: the peer is gone
                        else if (!pingOutstanding && now >= lastInput + opts.pingInterval)
                        {
                            sendControl(WsOpcode.ping, null);
                            pingOutstanding = true;
                            pingSentAt = now;
                        }
                    }
                    if (state != State.closed && now >= deadline)
                        return false;
                    break;
            }
        }
    }

    private static MonoTime earlier(MonoTime a, MonoTime b) pure nothrow @nogc => a < b ? a : b;

    /// Works through the buffered input. True when `m` holds a message or the close.
    private bool readMessage(out WsMessage m)
    {
        for (;;)
        {
            auto buf = io.buffered();
            if (!inFrame)
            {
                FrameHeader h;
                final switch (parseFrameHeader(buf, h))
                {
                    case FrameParse.needMore:
                        return false;
                    case FrameParse.badLength:
                        return fail(WsCloseCode.tooBig, m);
                    case FrameParse.ok:
                        break;
                }
                if (immutable err = frameError(h, !client, inMessage, deflateIn))
                    return fail(err, m);
                if (isControl(h.opcode))
                {
                    if (buf.length < h.headerLength + h.length)
                        return false;
                    ubyte[125] tmp = void;
                    auto payload = tmp[0 .. cast(size_t) h.length];
                    payload[] = buf[h.headerLength .. h.headerLength + payload.length];
                    if (h.masked)
                        applyMask(payload, h.mask, 0);
                    io.consume(h.headerLength + payload.length);
                    if (control(h.opcode, payload, m))
                        return true;
                    continue;
                }
                if (h.opcode != WsOpcode.continuation)
                {
                    inMessage = true;
                    msgOp = h.opcode;
                    msgCompressed = h.rsv1;
                    msg.clear();
                }
                if (h.length > opts.maxMessageBytes || msg.length + h.length > opts.maxMessageBytes)
                    return fail(WsCloseCode.tooBig, m);
                io.consume(h.headerLength);
                fh = h;
                inFrame = true;
                left = h.length;
                maskPos = 0;
                buf = io.buffered();
            }
            immutable n = left < buf.length ? cast(size_t) left : buf.length;
            if (n)
            {
                auto dst = cast(ubyte[]) msg.writable(n);
                dst[] = buf[0 .. n];
                if (fh.masked)
                    applyMask(dst, fh.mask, maskPos);
                msg.commit(n);
                io.consume(n);
                left -= n;
                maskPos += n;
            }
            if (left)
                return false;
            inFrame = false;
            if (!fh.fin)
                continue;
            inMessage = false;
            if (complete(m))
                return true;
            if (state == State.closed)
                return true; // complete() failed the connection; m holds the close
        }
    }

    /// A whole data message is in `msg`. True when it is delivered in `m` (or the connection failed: `m` is the close).
    private bool complete(out WsMessage m)
    {
        const(ubyte)[] payload = cast(const(ubyte)[]) msg.data;
        if (msgCompressed)
        {
            inflated.clear();
            final switch (deflater.decompress(payload, inflated, opts.maxMessageBytes))
            {
                case InflateResult.ok:
                    break;
                case InflateResult.tooBig:
                    return fail(WsCloseCode.tooBig, m);
                case InflateResult.error:
                    return fail(WsCloseCode.invalidData, m);
            }
            payload = cast(const(ubyte)[]) inflated.data;
        }
        if (msgOp == WsOpcode.text && !validUtf8(cast(const(char)[]) payload))
            return fail(WsCloseCode.invalidData, m);
        if (state != State.open)
            return false; // closing: data is discarded
        m = WsMessage(msgOp == WsOpcode.text ? WsKind.text : WsKind.binary, payload);
        return true;
    }

    /// A control frame arrived. True when it ends the connection (`m` is the close).
    private bool control(ubyte opcode, scope const(ubyte)[] payload, out WsMessage m)
    {
        if (opcode == WsOpcode.ping)
        {
            if (state == State.open)
                sendControl(WsOpcode.pong, payload);
            return false;
        }
        if (opcode == WsOpcode.pong)
            return false;
        // close
        ushort code = WsCloseCode.noStatus;
        const(ubyte)[] reason;
        if (payload.length == 1)
            return fail(WsCloseCode.protocolError, m);
        if (payload.length >= 2)
        {
            code = cast(ushort)((payload[0] << 8) | payload[1]);
            if (!validCloseCode(code))
                return fail(WsCloseCode.protocolError, m);
            reason = payload[2 .. $];
            if (!validUtf8(cast(const(char)[]) reason))
                return fail(WsCloseCode.invalidData, m);
        }
        if (state == State.open)
        {
            // echo the code (RFC 6455 §5.5.1); an empty close is answered with an empty close
            ubyte[2] echo = [cast(ubyte)(code >> 8), cast(ubyte)(code & 0xFF)];
            sendControl(WsOpcode.close, code == WsCloseCode.noStatus ? null : echo[]);
        }
        state = State.closed;
        code_ = code;
        reasonLen = reason.length;
        reason_[0 .. reasonLen] = reason[];
        m = closeMessage();
        return true;
    }

    /// Fails the connection (RFC 6455 §7.1.7): sends a close with `code` unless one was sent, and stops reading.
    private bool fail(ushort code, out WsMessage m)
    {
        if (state == State.open)
        {
            ubyte[2] p = [cast(ubyte)(code >> 8), cast(ubyte)(code & 0xFF)];
            sendControl(WsOpcode.close, p[]);
        }
        state = State.closed;
        code_ = code;
        reasonLen = 0;
        m = closeMessage();
        return true;
    }

    // ---- sending

    private void sendMessage(ubyte opcode, scope const(ubyte)[] data)
    {
        if (state != State.open)
            throw new WsClosed;
        frame.clear();
        bool compressed;
        if (deflater !is null && data.length >= compressMinBytes)
        {
            scratch.clear();
            compressed = deflater.compress(data, scratch);
        }
        if (compressed)
            putFrame(opcode, true, cast(const(ubyte)[]) scratch.data);
        else
            putFrame(opcode, false, data);
        io.write(cast(const(ubyte)[]) frame.data);
    }

    private void sendControl(ubyte opcode, scope const(ubyte)[] payload)
    {
        frame.clear();
        putFrame(opcode, false, payload);
        io.write(cast(const(ubyte)[]) frame.data);
    }

    private void sendClose(ushort code, scope const(ubyte)[] reason)
    {
        ubyte[125] p;
        p[0] = cast(ubyte)(code >> 8);
        p[1] = cast(ubyte)(code & 0xFF);
        immutable n = reason.length > 123 ? 123 : reason.length;
        p[2 .. 2 + n] = reason[0 .. n];
        state = State.closeSent;
        code_ = code;
        closeSentAt = MonoTime.currTime;
        sendControl(WsOpcode.close, p[0 .. 2 + n]);
    }

    private void putFrame(ubyte opcode, bool rsv1, scope const(ubyte)[] payload)
    {
        if (!client)
            return encodeFrame(frame, opcode, true, rsv1, payload);
        // xorshift64*: masking keys only have to be unpredictable to scripts in a browser, not secret
        rng ^= rng >> 12;
        rng ^= rng << 25;
        rng ^= rng >> 27;
        immutable uint k = cast(uint)((rng * 0x2545F4914F6CDD1DUL) >> 32);
        ubyte[4] key = [cast(ubyte) k, cast(ubyte)(k >> 8), cast(ubyte)(k >> 16), cast(ubyte)(k >> 24)];
        encodeFrame(frame, opcode, true, rsv1, payload, key[]);
    }
}

// ============================================================ tests

version (unittest)
{
    /// An in-memory connection: `input` is what the peer sent, `output` collects what we wrote.
    private final class MemConn : UpgradedConn
    {
        ubyte[] input;
        size_t pos, given;
        ByteBuffer output;
        bool closed, eofSent;
        size_t step = size_t.max; // bytes revealed per fill

        this(const(ubyte)[] bytes, size_t step = size_t.max)
        {
            input = bytes.dup;
            this.step = step;
            given = step == size_t.max ? input.length : 0;
        }

        override const(ubyte)[] buffered() => input[pos .. given];

        override FillResult fill(int timeoutMs)
        {
            if (given == input.length)
                return FillResult.eof;
            given = input.length - given < step ? input.length : given + step;
            return FillResult.data;
        }

        override void consume(size_t n)
        {
            pos += n;
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

    private ubyte[] clientFrame(ubyte opcode, const(ubyte)[] payload, bool fin = true, bool rsv1 = false)
    {
        ByteBuffer b;
        static immutable ubyte[4] key = [0x37, 0xfa, 0x21, 0x3d];
        encodeFrame(b, opcode, fin, rsv1, payload, key[]);
        return cast(ubyte[]) b.data.dup;
    }

    private ubyte[] cf(ubyte opcode, string s, bool fin = true) => clientFrame(opcode, cast(const(ubyte)[]) s, fin);

    /// Decodes the frames a server wrote (unmasked).
    private struct Out { ubyte opcode; string payload; bool rsv1; }

    private Out[] serverFrames(scope const(char)[] raw)
    {
        Out[] o;
        auto b = cast(const(ubyte)[]) raw;
        while (b.length)
        {
            FrameHeader h;
            assert(parseFrameHeader(b, h) == FrameParse.ok && !h.masked);
            o ~= Out(h.opcode, cast(string) b[h.headerLength .. h.headerLength + cast(size_t) h.length].idup, h.rsv1);
            b = b[h.headerLength + cast(size_t) h.length .. $];
        }
        return o;
    }

    private WsConn serverOn(MemConn io, WsOptions opts = WsOptions.init)
    {
        auto ws = new WsConn;
        opts.pingInterval = Duration.zero;
        ws.reset(io, false, opts);
        return ws;
    }
}

unittest // RFC 6455 §1.3: the accept key of the example handshake
{
    assert(acceptKey("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
    assert(validKey("dGhlIHNhbXBsZSBub25jZQ==") && !validKey("dGhlIHNhbXBsZSBub25jZQ") && !validKey("dGhlIHNhbXBsZSBub25jZ!=="));
}

unittest // frame header: every length class, masking, and a truncated header
{
    foreach (n; [0, 1, 125, 126, 127, 65_535, 65_536, 200_000])
    {
        auto payload = new ubyte[n];
        foreach (i, ref b; payload)
            b = cast(ubyte) i;
        foreach (masked; [false, true])
        {
            ByteBuffer o;
            static immutable ubyte[4] key = [1, 2, 3, 4];
            encodeFrame(o, WsOpcode.binary, true, false, payload, masked ? key[] : null);
            auto raw = cast(ubyte[]) o.data.dup;
            FrameHeader h;
            assert(parseFrameHeader(raw, h) == FrameParse.ok);
            assert(h.fin && h.opcode == WsOpcode.binary && h.masked == masked && h.length == n);
            assert(h.headerLength == (n < 126 ? 2 : n <= 65_535 ? 4 : 10) + (masked ? 4 : 0));
            auto body_ = raw[h.headerLength .. $];
            if (masked)
            {
                // unmask in two uneven pieces, as the receiver does when the payload arrives over several reads
                immutable cut = body_.length / 3;
                applyMask(body_[0 .. cut], h.mask, 0);
                applyMask(body_[cut .. $], h.mask, cut);
            }
            assert(body_ == payload);
            foreach (k; 0 .. h.headerLength)
                assert(parseFrameHeader(raw[0 .. k], h) == FrameParse.needMore);
        }
    }
    ubyte[10] huge = [0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0];
    FrameHeader h;
    assert(parseFrameHeader(huge, h) == FrameParse.badLength);
}

unittest // frame rules
{
    FrameHeader h;
    h.fin = true;
    h.masked = true;
    h.opcode = WsOpcode.text;
    assert(frameError(h, true, false, false) == 0);
    assert(frameError(h, false, false, false) == 1002, "a server's frame must not be masked");
    assert(frameError(h, true, true, false) == 1002, "a new message inside a fragmented one");
    h.rsv1 = true;
    assert(frameError(h, true, false, false) == 1002 && frameError(h, true, false, true) == 0);
    h.rsv1 = false;
    h.rsv2 = true;
    assert(frameError(h, true, false, true) == 1002);
    h.rsv2 = false;
    h.opcode = WsOpcode.continuation;
    assert(frameError(h, true, false, false) == 1002 && frameError(h, true, true, false) == 0);
    h.opcode = WsOpcode.ping;
    h.length = 126;
    assert(frameError(h, true, false, false) == 1002);
    h.length = 125;
    h.fin = false;
    assert(frameError(h, true, false, false) == 1002);
    h.fin = true;
    h.opcode = 3;
    assert(frameError(h, true, false, false) == 1002);
    assert(validCloseCode(1000) && validCloseCode(4999) && !validCloseCode(1005) && !validCloseCode(1006)
        && !validCloseCode(999) && !validCloseCode(1015) && !validCloseCode(2000));
}

unittest // handshake
{
    HeaderField[] hs = [ // (a heap array: `r` keeps a view into it)
        HeaderField("Host", "x"), HeaderField("Upgrade", "WebSocket"), HeaderField("Connection", "keep-alive, Upgrade"),
        HeaderField("Sec-WebSocket-Version", "13"), HeaderField("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
    ];
    Request r;
    r.headers = hs[];
    const(char)[] key;
    assert(checkUpgradeRequest(r, key) == WsHandshake.ok && key == "dGhlIHNhbXBsZSBub25jZQ==");
    hs[3].value = "8";
    assert(checkUpgradeRequest(r, key) == WsHandshake.badVersion);
    hs[3].value = "13";
    hs[4].value = "short";
    assert(checkUpgradeRequest(r, key) == WsHandshake.badKey);
    hs[2].value = "keep-alive";
    assert(checkUpgradeRequest(r, key) == WsHandshake.notUpgrade);
    hs[2].value = "upgrade";
    r.method = Method.POST;
    assert(checkUpgradeRequest(r, key) == WsHandshake.notUpgrade);
    r.method = Method.GET;
    r.protocol = Protocol.http2;
    assert(checkUpgradeRequest(r, key) == WsHandshake.notUpgrade, "a plain HTTP/2 GET");

    // RFC 8441: an extended CONNECT (presented as a GET) needs only the version
    HeaderField[] h2 = [HeaderField("sec-websocket-version", "13"), HeaderField("origin", "https://x")];
    r.headers = h2;
    r.connectProtocol = "websocket";
    assert(checkUpgradeRequest(r, key) == WsHandshake.ok && key is null);
    h2[0].value = "8";
    assert(checkUpgradeRequest(r, key) == WsHandshake.badVersion);
    h2[0].name = "x-other";
    assert(checkUpgradeRequest(r, key) == WsHandshake.badVersion);
    r.connectProtocol = "webtransport";
    assert(checkUpgradeRequest(r, key) == WsHandshake.notUpgrade);
}

unittest // permessage-deflate offers
{
    DeflateParams p;
    assert(parseDeflate("permessage-deflate", p) && p == DeflateParams.init);
    assert(parseDeflate("permessage-deflate; client_max_window_bits", p) && p.clientMaxWindowBitsSent && p.clientMaxWindowBits == 15);
    assert(parseDeflate("permessage-deflate;server_no_context_takeover; server_max_window_bits=\"10\"", p)
        && p.serverNoContextTakeover && p.serverMaxWindowBits == 10);
    assert(!parseDeflate("permessage-deflate; server_max_window_bits=16", p));
    assert(!parseDeflate("permessage-deflate; server_max_window_bits", p), "the server bits need a value");
    assert(!parseDeflate("permessage-deflate; foo", p));
    assert(!parseDeflate("permessage-deflate; server_no_context_takeover; server_no_context_takeover", p));
    assert(!parseDeflate("x-webkit-deflate-frame", p));

    HeaderField[2] hs = [HeaderField("Sec-WebSocket-Extensions", "foo, permessage-deflate; bad"),
        HeaderField("Sec-WebSocket-Extensions", "permessage-deflate; server_max_window_bits=9, permessage-deflate")];
    Request r;
    r.headers = hs[];
    assert(negotiateDeflate(r, p) && p.serverMaxWindowBits == 9);
    ByteBuffer o;
    writeDeflateResponse(o, p);
    assert(o.data == "permessage-deflate; server_max_window_bits=9", o.data.idup);
    hs[1].value = "foo";
    assert(!negotiateDeflate(r, p));
}

unittest // echo, fragments, ping, and the close handshake
{
    auto input = cf(WsOpcode.text, "hello") ~ cf(WsOpcode.ping, "p1") ~ cf(WsOpcode.binary, "ab", false)
        ~ cf(WsOpcode.ping, "mid") ~ cf(WsOpcode.continuation, "cd", false) ~ cf(WsOpcode.continuation, "", true)
        ~ clientFrame(WsOpcode.close, [0x03, 0xE8, 'b', 'y', 'e']);
    foreach (step; [size_t.max, 1, 3, 7]) // all at once, then byte by byte and in odd pieces
    {
        auto io = new MemConn(input, step);
        auto ws = serverOn(io);
        string[] got;
        foreach (m; ws)
        {
            got ~= (m.isText ? "t:" : "b:") ~ m.text.idup;
            ws.send(m.text);
        }
        assert(got == ["t:hello", "b:abcd"], got[0]);
        assert(!ws.isOpen && ws.closeCode == 1000 && ws.receive().isClose && ws.receive().text == "bye");
        auto o = serverFrames(io.output.data);
        assert(o == [Out(WsOpcode.text, "hello"), Out(WsOpcode.pong, "p1"), Out(WsOpcode.pong, "mid"),
            Out(WsOpcode.text, "abcd"), Out(WsOpcode.close, "\x03\xE8")]);
        ws.disconnect();
        assert(io.closed);
    }
}

unittest // protocol errors close the connection with the right code
{
    static ushort codeFor(ubyte[] input, size_t max = 1 << 20)
    {
        auto io = new MemConn(input);
        WsOptions opts;
        opts.maxMessageBytes = max;
        auto ws = serverOn(io, opts);
        auto m = ws.receive();
        assert(m.isClose);
        auto o = serverFrames(io.output.data);
        assert(o.length == 1 && o[0].opcode == WsOpcode.close);
        assert(((o[0].payload[0] << 8) | o[0].payload[1]) == m.closeCode);
        return m.closeCode;
    }

    assert(codeFor(cf(WsOpcode.text, "\xff\xfe")) == 1007, "invalid UTF-8");
    assert(codeFor(cf(WsOpcode.text, "abc", false) ~ cf(WsOpcode.continuation, "\xc3", true)) == 1007);
    assert(codeFor(cf(WsOpcode.text, "0123456789"), 5) == 1009, "too big");
    assert(codeFor(cf(WsOpcode.text, "0123", false) ~ cf(WsOpcode.continuation, "456"), 6) == 1009);
    assert(codeFor(cf(WsOpcode.continuation, "x")) == 1002, "continuation without a message");
    assert(codeFor(cf(WsOpcode.text, "x", false) ~ cf(WsOpcode.text, "y")) == 1002);
    assert(codeFor(clientFrame(WsOpcode.close, [0x03])) == 1002, "one-byte close");
    assert(codeFor(clientFrame(WsOpcode.close, [0x03, 0xED])) == 1002, "close code 1005 on the wire");
    assert(codeFor(clientFrame(WsOpcode.close, [0x03, 0xE8, 0xff])) == 1007, "invalid UTF-8 reason");
    assert(codeFor(clientFrame(WsOpcode.text, [0x41], true, true)) == 1002, "RSV1 without deflate");
    ByteBuffer unmasked;
    encodeFrame(unmasked, WsOpcode.text, true, false, cast(const(ubyte)[]) "hi");
    assert(codeFor(cast(ubyte[]) unmasked.data.dup) == 1002, "a client frame must be masked");
}

unittest // the server closes first; an empty close; the connection ends without a close
{
    // close() then disconnect(): the peer's answer ends the handshake, data in between is dropped
    auto io = new MemConn(cf(WsOpcode.text, "late") ~ clientFrame(WsOpcode.close, [0x0F, 0xA0]));
    auto ws = serverOn(io);
    ws.close(4000, "done");
    assert(!ws.isOpen);
    ws.disconnect();
    assert(io.closed && ws.closeCode == 4000);
    assert(serverFrames(io.output.data) == [Out(WsOpcode.close, "\x0F\xA0done")]);
    bool threw;
    try
        ws.send("x");
    catch (WsClosed)
        threw = true;
    assert(threw);

    io = new MemConn(clientFrame(WsOpcode.close, null));
    ws = serverOn(io);
    assert(ws.receive().closeCode == 1005);
    assert(serverFrames(io.output.data) == [Out(WsOpcode.close, "")]);

    io = new MemConn(cf(WsOpcode.text, "a"));
    ws = serverOn(io);
    assert(ws.receive().text == "a");
    auto m = ws.receive();
    assert(m.isClose && m.closeCode == 1006 && io.output.length == 0);
}

unittest // a client masks what it sends and rejects masked frames from the server
{
    auto io = new MemConn(null);
    auto ws = new WsConn;
    ws.reset(io, true, WsOptions.init, null, 42);
    ws.send("hi");
    FrameHeader h;
    auto raw = cast(ubyte[]) io.output.data.dup;
    assert(parseFrameHeader(raw, h) == FrameParse.ok && h.masked && h.length == 2);
    auto p = raw[h.headerLength .. $];
    applyMask(p, h.mask, 0);
    assert(p == "hi");

    ByteBuffer fromServer;
    encodeFrame(fromServer, WsOpcode.text, true, false, cast(const(ubyte)[]) "ok");
    io = new MemConn(cast(ubyte[]) fromServer.data.dup);
    ws.reset(io, true, WsOptions.init, null, 42);
    assert(ws.receive().text == "ok");
}
