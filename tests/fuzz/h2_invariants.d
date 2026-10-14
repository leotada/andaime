/// What must hold for any byte sequence an HTTP/2 client sends (shared by the mutation fuzzer
/// and the libFuzzer target): the session never crashes, consumes no more than it was given,
/// only ever emits well-formed frames, answers every request it hands out, and ends with a
/// GOAWAY when it gives up on the connection.
module h2_invariants;

import vela.http;

/// The valid connection start every input is appended to (fuzzers then explore the frames).
immutable ubyte[] h2Start = cast(immutable(ubyte)[]) (clientPreface ~ "\x00\x00\x00\x04\x00\x00\x00\x00\x00");

/// One session for every input, reset in between: that is how the engine pools sessions, so
/// `reset` gets fuzzed too (a stale field once survived it), and nothing is allocated per input
/// (the D GC is not collected under the libFuzzer driver; per-input garbage would only grow).
private H2Session session;
private ubyte[] inbuf;
private size_t inLen;
// WebSockets over HTTP/2 (RFC 8441) the "engine" accepted: it consumes their input, echoes part of it, and ends them
private H2Stream[8] tunnels;
private size_t nTunnels;
private Object engineTask;
private long clock;

void checkH2(scope const(ubyte)[] input)
{
    if (session is null)
    {
        H2Config cfg;
        cfg.maxConcurrentStreams = 8;
        cfg.limits.maxBodyBytes = 64 << 10;
        session = new H2Session(cfg);
        inbuf = new ubyte[256 << 10];
        engineTask = new Object;
    }
    else
        session.reset();
    // feed the start, then the input in two pieces (split point taken from the input itself)
    inLen = 0;
    clock = 0;
    append(h2Start);
    immutable split = input.length ? input[0] % (input.length + 1) : 0;
    feed(session, input[0 .. split]);
    feed(session, input[split .. $]);
    // the engine gives every tunnel back before the session is reset (as closeH2 does)
    foreach (t; tunnels[0 .. nTunnels])
        session.endResponse(t);
    nTunnels = 0;
    checkOutput(session);
}

private void append(scope const(ubyte)[] more)
{
    if (inLen + more.length > inbuf.length)
        more = more[0 .. inbuf.length - inLen]; // inputs are capped well below this
    inbuf[inLen .. inLen + more.length] = more[];
    inLen += more.length;
}

private void feed(H2Session s, scope const(ubyte)[] more)
{
    append(more);
    immutable n = s.receive(inbuf[0 .. inLen]);
    assert(n <= inLen, "consumed more than it was given");
    foreach (i; 0 .. inLen - n)
        inbuf[i] = inbuf[n + i];
    inLen -= n;
    // the engine's side: answer whatever became ready, cancel whatever was reset
    H2Stream st;
    while (s.popReset(st))
    {
        foreach (i, t; tunnels[0 .. nTunnels])
            if (t is st)
            {
                tunnels[i] = tunnels[--nTunnels];
                break;
            }
        s.detach(st);
    }
    while (s.popReady(st))
    {
        assert(st.req.protocol == Protocol.http2 && st.req.path.length && st.req.path[0] == '/'
            || st.req.target == "*");
        if (st.tunnel)
        {
            assert(st.req.method == Method.GET && st.req.connectProtocol == "websocket", "a tunnel is a GET + websocket");
            if (nTunnels < tunnels.length)
            {
                st.task = engineTask; // the handler accepts the WebSocket
                const ResponseHead ok = ResponseHead(200, null, null, -1);
                s.beginResponse(st, ok, false);
                tunnels[nTunnels++] = st;
                continue;
            }
        }
        else
            assert(st.req.connectProtocol is null);
        static ByteBuffer o;
        o.clear();
        o.put("abc");
        static immutable HeaderField[1] extra = [HeaderField("X-A", "b")];
        const ResponseHead head = ResponseHead(200, null, extra[], 3);
        s.respond(st, head, o);
    }
    while (s.popInput(st))
        assert(st.task is engineTask, "input for a stream the engine does not hold");
    // the WebSockets' owners: consume what came, echo the start of it, end the ones whose peer ended (or that got 'q')
    for (size_t i = 0; i < nTunnels;)
    {
        auto t = tunnels[i];
        auto inp = s.tunnelInput(t);
        assert(inp.length <= (256 << 10), "a tunnel holds more than a stream window");
        immutable quit = inp.length && inp[0] == 'q';
        if (inp.length)
        {
            s.sendData(t, cast(const(char)[]) inp[0 .. inp.length < 100 ? inp.length : 100]);
            s.tunnelConsume(t, inp.length);
        }
        if (s.tunnelEnded(t) || quit)
        {
            s.endResponse(t);
            tunnels[i] = tunnels[--nTunnels];
            continue;
        }
        i++;
    }
    clock += 700;
    s.tick(clock); // resets the tunnels whose peer never ended its side
    checkOutput(s);
}

/// The output is a sequence of complete, well-formed frames.
private void checkOutput(H2Session s)
{
    auto o = cast(const(ubyte)[]) s.pendingOutput;
    size_t p = 0;
    bool sawGoAway = false;
    while (p < o.length)
    {
        assert(o.length - p >= 9, "truncated frame header in the output");
        immutable len = (o[p] << 16) | (o[p + 1] << 8) | o[p + 2];
        immutable type = o[p + 3];
        immutable sid = ((o[p + 5] & 0x7f) << 24) | (o[p + 6] << 16) | (o[p + 7] << 8) | o[p + 8];
        assert(o.length - p >= 9 + len, "truncated frame payload in the output");
        assert(type <= FrameType.continuation && type != FrameType.pushPromise, "unexpected frame type");
        final switch (cast(FrameType) type)
        {
            case FrameType.data, FrameType.headers, FrameType.continuation, FrameType.rstStream:
                assert(sid != 0 && (sid & 1), "stream frame on stream 0 or an even stream");
                break;
            case FrameType.settings, FrameType.ping, FrameType.goAway:
                assert(sid == 0, "connection frame on a stream");
                break;
            case FrameType.windowUpdate, FrameType.priority:
                break;
            case FrameType.pushPromise:
                assert(0);
        }
        if (type == FrameType.rstStream || type == FrameType.windowUpdate)
            assert(len == 4);
        if (type == FrameType.goAway)
        {
            assert(len == 8);
            sawGoAway = true;
        }
        p += 9 + len;
    }
    if (s.fatal)
        assert(sawGoAway || s.goAwaySent, "a connection error without GOAWAY");
    s.sent(o.length);
}
