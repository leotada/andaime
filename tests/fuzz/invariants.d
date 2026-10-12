/// Invariants the request parser must respect for ANY input.
/// Used by the mutation fuzzer (CI) and by libFuzzer (tools/fuzz.sh).
module invariants;

import vela.http.parser;
import vela.http.types;

private bool within(const(char)[] inner, const(char)[] outer)
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

void check(const(char)[] buf, in Limits lim = Limits.init)
{
    HeaderField[32] store;
    Request r;
    auto h = parseRequestHead(buf, r, store[], lim);

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

            bool sawLen;
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
                assert(!equalsIgnoreCase(hf.name, "transfer-encoding"), "TE accepted: smuggling risk");
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

            // the head does not "complete" before its end, and bytes after it do not change the result
            Request r2;
            HeaderField[32] s2;
            auto h2 = parseRequestHead(buf[0 .. h.headLength], r2, s2[], lim);
            assert(h2.status == ParseStatus.complete && h2.headLength == h.headLength
                && h2.contentLength == h.contentLength && r2.method == r.method && r2.path == r.path);
            foreach (k; [h.headLength - 1, h.headLength - 2, h.headLength - 4, h.headLength / 2, 0])
            {
                Request r3;
                HeaderField[32] s3;
                assert(parseRequestHead(buf[0 .. k], r3, s3[], lim).status != ParseStatus.complete,
                    "a prefix of the head was accepted as complete");
            }
            break;
    }
}
