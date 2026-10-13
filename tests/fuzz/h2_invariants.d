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

void checkH2(scope const(ubyte)[] input)
{
    if (session is null)
    {
        H2Config cfg;
        cfg.maxConcurrentStreams = 8;
        cfg.limits.maxBodyBytes = 64 << 10;
        session = new H2Session(cfg);
        inbuf = new ubyte[256 << 10];
    }
    else
        session.reset();
    // feed the start, then the input in two pieces (split point taken from the input itself)
    inLen = 0;
    append(h2Start);
    immutable split = input.length ? input[0] % (input.length + 1) : 0;
    feed(session, input[0 .. split]);
    feed(session, input[split .. $]);
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
        s.detach(st);
    while (s.popReady(st))
    {
        assert(st.req.protocol == Protocol.http2 && st.req.path.length && st.req.path[0] == '/'
            || st.req.target == "*");
        static ByteBuffer o;
        o.clear();
        o.put("abc");
        static immutable HeaderField[1] extra = [HeaderField("X-A", "b")];
        const ResponseHead head = ResponseHead(200, null, extra[], 3);
        s.respond(st, head, o);
    }
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
