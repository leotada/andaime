/// Invariants the request parser must respect for ANY input.
/// Used by the mutation fuzzer (CI) and by libFuzzer (tools/fuzz.sh).
module invariants;

@safe:

import andaime.http.parser;
import andaime.http.types;
import andaime.http.chunked;

private bool within(const(char)[] inner, const(char)[] outer) @trusted // only compares addresses
{
    if (inner.length == 0)
        return true;
    return inner.ptr >= outer.ptr && inner.ptr + inner.length <= outer.ptr + outer.length;
}

private bool isTokenChar(char c)
{
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return true;
    foreach (t; "!#$%&'*+-.^_`|~")
        if (c == t)
            return true;
    return false;
}

private ptrdiff_t indexOf(const(char)[] hay, string needle)
{
    if (hay.length < needle.length)
        return -1;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle)
            return i;
    return -1;
}

/// The chunked decoder on ANY bytes: feeding them all at once, one by one, or in pieces taken from the data itself must
/// give the same verdict and the same body, and the decoded body can never be longer than the input. Uses fixed buffers:
/// the fuzzers run millions of inputs and garbage would make libFuzzer's RSS limit trip.
void checkChunked(const(char)[] input)
{
    enum maxIn = 4096;
    static ubyte[maxIn + 8] region;
    static ubyte[maxIn + 8][3] bodies;
    auto data = input.length > maxIn ? input[0 .. maxIn] : input;

    // mode 0: all at once, 1: byte by byte, 2: pieces of 1..7 bytes chosen by the data itself
    ChunkResult run(int mode, out size_t bodyLen)
    {
        size_t avail, pos, k;
        ChunkedDecoder d;
        ChunkResult last = ChunkResult.needMore;
        while (pos < data.length)
        {
            size_t take = data.length - pos;
            if (mode == 1)
                take = 1;
            else if (mode == 2)
            {
                immutable want = 1 + (cast(ubyte) data[k++ % data.length]) % 7;
                take = want < take ? want : take;
            }
            region[avail .. avail + take] = cast(const(ubyte)[]) data[pos .. pos + take];
            avail += take;
            pos += take;
            last = d.feed(region[0 .. maxIn + 8], avail, 4096, 256);
            assert(d.decoded <= avail && avail <= pos, "the decoder invented or lost bytes");
            if (last != ChunkResult.needMore)
                break;
        }
        bodyLen = d.decoded;
        bodies[mode][0 .. bodyLen] = region[0 .. bodyLen];
        return last;
    }

    size_t n0, n1, n2;
    immutable r0 = run(0, n0);
    immutable r1 = run(1, n1);
    immutable r2 = run(2, n2);
    assert(r0 == r1 && r0 == r2, "the verdict depends on how the bytes were split");
    assert(n0 == n1 && n0 == n2 && bodies[0][0 .. n0] == bodies[1][0 .. n1] && bodies[0][0 .. n0] == bodies[2][0 .. n2],
        "the body depends on how the bytes were split");
    assert(n0 <= data.length);
}

void check(const(char)[] buf, in Limits lim = Limits.init)
{
    checkChunked(buf);
    auto store = new HeaderField[32]; // (heap: `r` keeps views into the store)
    Request r;
    auto h = parseRequestHead(buf, r, store, lim);

    final switch (h.status)
    {
        case ParseStatus.incomplete:
            assert(indexOf(buf, "\r\n\r\n") < 0, "incomplete, but the end of the head is in the buffer");
            break;
        case ParseStatus.error:
            switch (h.errorStatus)
            {
                case 400, 413, 414, 417, 431, 501, 505: break;
                default: assert(0, "unexpected error status");
            }
            break;
        case ParseStatus.complete:
            assert(h.headLength >= 16 && h.headLength <= buf.length);
            assert(buf[h.headLength - 4 .. h.headLength] == "\r\n\r\n");
            assert(indexOf(buf[0 .. h.headLength - 2], "\r\n\r\n") < 0, "head ends earlier than the parser said");
            auto head = buf[0 .. h.headLength];
            assert(r.method != Method.unknown);
            assert(within(r.target, head) && within(r.path, head) && within(r.query, head));
            assert(r.target.length > 0 && (r.target[0] == '/' || r.target == "*"));
            foreach (char c; r.target)
                assert(c > ' ' && c != 0x7f, "control character in the target");
            assert(h.contentLength <= lim.maxBodyBytes);
            assert(r.headers.length <= store.length);

            bool sawLen, sawTE;
            size_t firstLen;
            foreach (ref hf; r.headers)
            {
                assert(within(hf.name, head) && within(hf.value, head));
                assert(hf.name.length > 0);
                foreach (char c; hf.name)
                    assert(isTokenChar(c), "invalid header name accepted");
                foreach (char c; hf.value)
                    assert(c != '\r' && c != '\n' && c != 0, "CR/LF/NUL accepted in the value");
                assert(hf.value.length == 0 || (hf.value[0] != ' ' && hf.value[0] != '\t'));
                assert(hf.value.length == 0 || (hf.value[$ - 1] != ' ' && hf.value[$ - 1] != '\t'));
                if (equalsIgnoreCase(hf.name, "transfer-encoding"))
                {
                    assert(!sawTE, "two Transfer-Encoding headers accepted: smuggling risk");
                    assert(equalsIgnoreCase(hf.value, "chunked"), "a coding other than plain chunked accepted");
                    sawTE = true;
                }
                if (equalsIgnoreCase(hf.name, "content-length"))
                {
                    size_t v;
                    assert(hf.value.length > 0 && hf.value.length <= 18);
                    foreach (char c; hf.value)
                    {
                        assert(c >= '0' && c <= '9', "non-numeric Content-Length accepted");
                        v = v * 10 + (c - '0');
                    }
                    if (sawLen)
                        assert(v == firstLen, "conflicting Content-Length values accepted");
                    sawLen = true;
                    firstLen = v;
                }
            }
            assert(sawLen ? h.contentLength == firstLen : h.contentLength == 0);
            assert(h.chunked == sawTE);
            if (sawTE)
                assert(!sawLen && r.http11 && h.contentLength == 0, "chunked next to Content-Length, or on HTTP/1.0");
            if (h.chunked)
                checkChunked(buf[h.headLength .. $]);

            // the head does not "complete" before its end, and bytes after it do not change the result
            Request r2;
            auto s2 = new HeaderField[32];
            auto h2 = parseRequestHead(buf[0 .. h.headLength], r2, s2, lim);
            assert(h2.status == ParseStatus.complete && h2.headLength == h.headLength
                && h2.contentLength == h.contentLength && r2.method == r.method && r2.path == r.path);
            foreach (k; [h.headLength - 1, h.headLength - 2, h.headLength - 4, h.headLength / 2, 0])
            {
                Request r3;
                auto s3 = new HeaderField[32];
                assert(parseRequestHead(buf[0 .. k], r3, s3, lim).status != ParseStatus.complete,
                    "a prefix of the head was accepted as complete");
            }
            break;
    }
}
