/// Decoder for `Transfer-Encoding: chunked` request bodies (RFC 9112 §7.1). Pure and incremental: no I/O, no allocation.
///
/// It works in place on the connection's buffer. The caller owns a region that starts right after the request head and
/// holds the raw bytes received so far; `feed` rewrites it so that the first `decoded` bytes are the body and whatever
/// raw bytes are still undigested (a partial chunk header, or the next pipelined request after the end) follow
/// directly behind. So after `done`, `region[0 .. decoded]` is the body and `region[decoded .. avail]` is the next
/// request, which is exactly what the engine's `compact` expects.
///
///     auto st = dec.feed(region, avail, maxBody, maxTrailerBytes);   // call again when more bytes arrive
module vela.http.chunked;

@safe:

enum ChunkResult : ubyte
{
    needMore,   /// all received bytes were digested; more are needed
    done,       /// the last chunk and the trailers ended: the body is complete
    badRequest, /// malformed framing (400)
    tooLarge,   /// the decoded body is above the limit (413)
}

struct ChunkedDecoder
{
    private enum State : ubyte
    {
        sizeLine,    // hex digits of the chunk size
        extension,   // after ';' until CR
        sizeLf,      // expecting LF after the CR of the size line
        data,        // chunk payload
        dataCr,      // expecting CR after the payload
        dataLf,      // expecting LF after that CR
        trailerStart,// start of a trailer line, or the empty line that ends the message
        trailerName, // inside a trailer line (up to CR)
        trailerLf,   // expecting LF after the CR of a trailer line
        endLf,       // expecting the LF of the final empty line
        finished,
    }

    private State state;
    private ulong remaining;      // payload bytes of the current chunk still to come
    private ulong size;           // chunk size being parsed
    private uint digits;
    private uint extBytes;
    private size_t trailerBytes;
    private size_t outPos;        // decoded bytes so far (== start of the undigested region after compaction)
    private size_t decodedTotal;

    /// Size of the decoded body so far.
    size_t decoded() const pure nothrow @nogc => outPos;

    /// Digests `region[outPos .. avail]` (everything new). `avail` is updated: after the call the region holds the
    /// decoded body followed by the undigested bytes, and `avail` is its new length.
    ChunkResult feed(scope ubyte[] region, ref size_t avail, size_t maxBody, size_t maxTrailerBytes) pure nothrow @nogc
    {
        size_t i = outPos;       // next raw byte to read; outPos <= i always (bytes between are already digested)
        size_t o = outPos;       // next decoded byte to write
        // everything before `o` is body; raw input is region[i .. avail]
        ChunkResult result = ChunkResult.needMore;
        scope (exit)
        {
            // squeeze: move the undigested bytes right behind the decoded ones
            if (i > o)
            {
                foreach (k; 0 .. avail - i)
                    region[o + k] = region[i + k];
                avail -= i - o;
            }
            outPos = o;
        }
        while (i < avail)
        {
            final switch (state)
            {
                case State.sizeLine:
                {
                    immutable c = region[i];
                    int d = -1;
                    if (c >= '0' && c <= '9') d = c - '0';
                    else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
                    else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
                    if (d >= 0)
                    {
                        if (++digits > 16 || (size >> 60) != 0)
                            return ChunkResult.tooLarge; // absurd size (also guards the overflow of size * 16)
                        size = size * 16 + d;
                        i++;
                    }
                    else if (digits == 0)
                        return ChunkResult.badRequest;
                    else if (c == ';')
                    {
                        state = State.extension;
                        extBytes = 0;
                        i++;
                    }
                    else if (c == '\r')
                    {
                        state = State.sizeLf;
                        i++;
                    }
                    else
                        return ChunkResult.badRequest; // whitespace, bare LF...: strict
                    break;
                }
                case State.extension:
                {
                    immutable c = region[i];
                    if (c == '\r')
                        state = State.sizeLf;
                    else if (c == '\n' || c == 0 || ++extBytes > 256)
                        return ChunkResult.badRequest;
                    i++;
                    break;
                }
                case State.sizeLf:
                    if (region[i] != '\n')
                        return ChunkResult.badRequest;
                    i++;
                    if (size == 0)
                    {
                        state = State.trailerStart;
                        trailerBytes = 0;
                    }
                    else
                    {
                        if (decodedTotal + size > maxBody)
                            return ChunkResult.tooLarge;
                        remaining = size;
                        state = State.data;
                    }
                    size = 0;
                    digits = 0;
                    break;
                case State.data:
                {
                    immutable avl = avail - i;
                    immutable take = remaining < avl ? cast(size_t) remaining : avl;
                    // move the payload left over the framing (o <= i, so a forward copy is safe)
                    foreach (k; 0 .. take)
                        region[o + k] = region[i + k];
                    o += take;
                    i += take;
                    decodedTotal += take;
                    remaining -= take;
                    if (remaining == 0)
                        state = State.dataCr;
                    break;
                }
                case State.dataCr:
                    if (region[i] != '\r')
                        return ChunkResult.badRequest;
                    state = State.dataLf;
                    i++;
                    break;
                case State.dataLf:
                    if (region[i] != '\n')
                        return ChunkResult.badRequest;
                    state = State.sizeLine;
                    i++;
                    break;
                case State.trailerStart:
                    if (region[i] == '\r')
                        state = State.endLf;
                    else
                        state = State.trailerName;
                    if (state == State.endLf)
                        i++;
                    break;
                case State.trailerName:
                {
                    immutable c = region[i];
                    if (c == '\r')
                        state = State.trailerLf;
                    else if (c == '\n' || c == 0 || ++trailerBytes > maxTrailerBytes)
                        return ChunkResult.badRequest;
                    i++;
                    break;
                }
                case State.trailerLf:
                    if (region[i] != '\n')
                        return ChunkResult.badRequest;
                    state = State.trailerStart;
                    i++;
                    break;
                case State.endLf:
                    if (region[i] != '\n')
                        return ChunkResult.badRequest;
                    i++;
                    state = State.finished;
                    return ChunkResult.done;
                case State.finished:
                    return ChunkResult.done;
            }
        }
        return state == State.finished ? ChunkResult.done : result;
    }
}

version (unittest)
{
    /// Decodes `raw` fed in pieces of `step` bytes (0 = all at once). Returns the body and what follows the message.
    private bool decodeAll(string raw, size_t step, out string body_, out string rest, out ChunkResult last,
        size_t maxBody = 1 << 20)
    {
        ubyte[] region = new ubyte[raw.length + 16];
        size_t avail;
        ChunkedDecoder d;
        size_t pos;
        while (true)
        {
            immutable take = step == 0 ? raw.length - pos : (raw.length - pos < step ? raw.length - pos : step);
            region[avail .. avail + take] = cast(const(ubyte)[]) raw[pos .. pos + take];
            avail += take;
            pos += take;
            last = d.feed(region, avail, maxBody, 1024);
            if (last != ChunkResult.needMore || pos == raw.length)
                break;
        }
        body_ = cast(string) region[0 .. d.decoded].idup;
        rest = last == ChunkResult.done ? cast(string) region[d.decoded .. avail].idup : "";
        return last == ChunkResult.done;
    }
}

unittest
{
    string b, rest;
    ChunkResult r;
    // whatever the split of the input, the result is the same
    foreach (step; [0UL, 1, 2, 3, 5, 7, 64])
    {
        assert(decodeAll("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", step, b, rest, r) && b == "hello world" && rest == "", b);
        // (the helper stops feeding at `done`, so the tail is only there when it arrived in the same piece)
        assert(decodeAll("5\r\nhello\r\n0\r\n\r\nGET /next HTTP/1.1\r\n\r\n", step, b, rest, r) && b == "hello"
            && (step != 0 && step < 20 || rest == "GET /next HTTP/1.1\r\n\r\n"), "pipelined request must follow the body: " ~ rest);
        assert(decodeAll("A\r\n0123456789\r\n0\r\n\r\n", step, b, rest, r) && b == "0123456789", "hex size");
        assert(decodeAll("a;name=value;x\r\n0123456789\r\n0\r\n\r\n", step, b, rest, r) && b == "0123456789", "extensions are ignored");
        assert(decodeAll("3\r\nabc\r\n0\r\nX-Checksum: 123\r\nOther: v\r\n\r\n", step, b, rest, r) && b == "abc", "trailers are discarded");
        assert(decodeAll("0\r\n\r\n", step, b, rest, r) && b == "", "an empty body");
        assert(decodeAll("2\r\n\r\n\r\n0\r\n\r\n", step, b, rest, r) && b == "\r\n", "CRLF inside a chunk is payload");
        assert(decodeAll("00000000000000005\r\nhello\r\n0\r\n\r\n", step, b, rest, r) || r == ChunkResult.tooLarge, "17 digits are refused");
    }

    // malformed framing: 400
    foreach (bad; ["x\r\n", "-1\r\n", " 5\r\nhello\r\n0\r\n\r\n", "5 \r\nhello\r\n0\r\n\r\n", "5\nhello\r\n0\r\n\r\n",
        "5\r\nhello\n0\r\n\r\n", "5\r\nhelloXX0\r\n\r\n", "5\r\nhello\r\n0\r\n\n", "\r\n", ";\r\n", "5;\n\r\n",
        "5\r\nhello\r\n0\r\nbad\0line\r\n\r\n"])
        foreach (step; [0UL, 1, 4])
        {
            decodeAll(bad, step, b, rest, r);
            assert(r == ChunkResult.badRequest, "should be rejected: " ~ bad);
        }

    // incomplete: needMore, never done
    foreach (part; ["", "5", "5\r", "5\r\nhel", "5\r\nhello", "5\r\nhello\r", "5\r\nhello\r\n", "5\r\nhello\r\n0", "5\r\nhello\r\n0\r\n",
        "5\r\nhello\r\n0\r\n\r", "5\r\nhello\r\n0\r\nT: v\r\n"])
    {
        decodeAll(part, 0, b, rest, r);
        assert(r == ChunkResult.needMore, part);
    }

    // limits: the decoded size is checked when a chunk is announced, so a huge chunk is refused before its payload arrives
    decodeAll("10\r\n0123456789abcdef\r\n0\r\n\r\n", 0, b, rest, r, 15);
    assert(r == ChunkResult.tooLarge);
    decodeAll("FFFFFFFFFFFFFFFF\r\n", 0, b, rest, r);
    assert(r == ChunkResult.tooLarge, "an overflowing size must not wrap around");
    decodeAll("5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n", 0, b, rest, r, 9);
    assert(r == ChunkResult.tooLarge, "the sum of the chunks counts");
    decodeAll("0\r\n" ~ "X: " ~ "a".repeatStr(2000) ~ "\r\n\r\n", 0, b, rest, r);
    assert(r == ChunkResult.badRequest, "trailers are bounded");
    decodeAll("1;" ~ "e".repeatStr(300) ~ "\r\nx\r\n0\r\n\r\n", 0, b, rest, r);
    assert(r == ChunkResult.badRequest, "extensions are bounded");
}

version (unittest) private string repeatStr(string s, size_t n)
{
    string r;
    foreach (_; 0 .. n)
        r ~= s;
    return r;
}
