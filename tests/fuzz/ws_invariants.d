/// What must hold for any byte sequence a WebSocket client sends (shared by the mutation fuzzer and the libFuzzer
/// target): the server side of `WsConn` never crashes, never consumes more than it was given, delivers only messages
/// within the size limit (text ones valid UTF-8), always ends with a close, and only ever writes well-formed, unmasked
/// frames with at most one close frame, last.
module ws_invariants 2025;

import andaime.http;
import core.time : Duration;

enum maxMessage = 4096;

/// permessage-deflate without zlib (the fuzz build links only andaime:http): "inflating" copies the payload, and a payload
/// that starts with 0xFF is corrupt. That is enough to run the RSV1 paths.
final class FakeDeflate : WsDeflate
{
    override bool compress(scope const(ubyte)[] message, ref ByteBuffer o) @safe => false;

    override InflateResult decompress(scope const(ubyte)[] payload, ref ByteBuffer o, size_t limit) @safe
    {
        if (payload.length && payload[0] == 0xFF)
            return InflateResult.error;
        if (payload.length > limit)
            return InflateResult.tooBig;
        o.put(cast(const(char)[]) payload);
        return InflateResult.ok;
    }

    override void release() @safe
    {
    }
}

/// The input revealed a few bytes per `fill`, as reads off a socket would.
final class Input : UpgradedConn
{
    const(ubyte)[] input;
    size_t pos, given, step;
    ByteBuffer output;
    bool closed;

    void reset(const(ubyte)[] bytes, size_t step) @safe
    {
        input = bytes;
        pos = given = 0;
        this.step = step;
        output.clear();
        closed = false;
    }

    override const(ubyte)[] buffered() @safe => input[pos .. given];

    override FillResult fill(int timeoutMs) @safe
    {
        if (given == input.length)
            return FillResult.eof;
        given = input.length - given < step ? input.length : given + step;
        return FillResult.data;
    }

    override void consume(size_t n) @safe
    {
        assert(pos + n <= given, "consumed more than was buffered");
        pos += n;
    }

    override void write(scope const(ubyte)[] data) @safe
    {
        assert(!closed, "wrote after close");
        output.put(cast(const(char)[]) data);
    }

    override void close() @safe
    {
        closed = true;
    }
}

// one of each for every input, reset in between (nothing allocated per input: the GC is not collected under libFuzzer)
private WsConn ws;
private Input io;
private FakeDeflate fake;

void checkWs(scope const(ubyte)[] input)
{
    if (ws is null)
    {
        ws = new WsConn;
        io = new Input;
        fake = new FakeDeflate;
    }
    immutable first = input.length ? input[0] : 0;
    io.reset(input, 1 + first % 64);
    WsOptions opts;
    opts.maxMessageBytes = maxMessage;
    opts.pingInterval = Duration.zero;
    opts.closeTimeout = Duration.zero;
    ws.reset(io, false, opts, (first & 1) ? fake : null);

    size_t messages;
    for (;;)
    {
        auto m = ws.receive();
        if (m.isClose)
        {
            assert(m.closeCode == 1005 || m.closeCode == 1006 || validCloseCode(m.closeCode), "bad close code reported");
            assert(validUtf8(cast(const(char)[]) m.data), "the close reason is not UTF-8");
            break;
        }
        assert(m.data.length <= maxMessage, "a message above the limit was delivered");
        assert(!m.isText || validUtf8(m.text), "a text message that is not UTF-8 was delivered");
        messages++;
        assert(messages <= input.length / 2 + 1, "more messages than the input could hold");
        if (messages % 3 == 0) // sending works in between
        {
            if (m.isText)
                ws.send(m.text);
            else
                ws.sendBinary(m.data);
        }
    }
    assert(!ws.isOpen);
    ws.disconnect();
    assert(io.closed, "the transport was not closed");
    checkOutput(cast(const(ubyte)[]) io.output.data);
}

/// Everything the server wrote parses as unmasked frames; a close frame, if any, is the last one and carries a valid code.
private void checkOutput(const(ubyte)[] b)
{
    bool closeSeen;
    while (b.length)
    {
        assert(!closeSeen, "a frame after the close frame");
        FrameHeader h;
        assert(parseFrameHeader(b, h) == FrameParse.ok, "a truncated frame header in the output");
        assert(!h.masked && h.fin && !h.rsv2 && !h.rsv3, "a server frame must be unmasked and final");
        assert(b.length >= h.headerLength + h.length, "a truncated frame in the output");
        auto p = b[h.headerLength .. h.headerLength + cast(size_t) h.length];
        switch (h.opcode)
        {
            case WsOpcode.text:
                assert(validUtf8(cast(const(char)[]) p));
                break;
            case WsOpcode.binary:
            case WsOpcode.pong:
                break;
            case WsOpcode.close:
                closeSeen = true;
                assert(p.length == 0 || (p.length >= 2 && validCloseCode((p[0] << 8) | p[1])), "bad close code sent");
                break;
            default:
                assert(0, "unexpected opcode in the output");
        }
        b = b[h.headerLength + cast(size_t) h.length .. $];
    }
}
