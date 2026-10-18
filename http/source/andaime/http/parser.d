/// Incremental, zero-copy parser for the head of an HTTP/1.1 request.
/// Pure (no I/O): takes bytes, returns slices. Fuzzing target since M3.
module andaime.http.parser 2025;

import andaime.http.types;

@safe:

struct Limits
{
    size_t maxHeadBytes = 8 * 1024;   /// 431 above this
    size_t maxTargetBytes = 4 * 1024; /// 414 above this
    size_t maxBodyBytes = 1024 * 1024; /// 413 above this
}

enum ParseStatus { complete, incomplete, error }

struct HeadResult
{
    ParseStatus status;
    size_t headLength;    /// head bytes, including the final CRLFCRLF
    size_t contentLength; /// size of the body to read after the head (0 when `chunked`)
    bool chunked;         /// `Transfer-Encoding: chunked`: the body length is not known up front (see andaime.http.chunked)
    int errorStatus;      /// HTTP status to respond with when status == error
}

private HeadResult fail(int code) pure nothrow @nogc
{
    return HeadResult(ParseStatus.error, 0, 0, false, code);
}

/// Finds "\r\n\r\n". M4 replaces it with a vectorized search (core.simd).
private ptrdiff_t findHeadEnd(scope const(char)[] buf) pure nothrow @nogc
{
    if (buf.length < 4)
        return -1;
    foreach (i; 0 .. buf.length - 3)
        if (buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n')
            return i;
    return -1;
}

/// Parses the head in `buf`. On `complete`, all slices of `req`
/// point inside `buf`; `headerStore` is supplied by the caller
/// (the connection's fixed array), so nothing is allocated.
HeadResult parseRequestHead(const(char)[] buf, ref Request req,
    HeaderField[] headerStore, in Limits limits = Limits.init) pure nothrow @nogc
{
    auto end = findHeadEnd(buf);
    if (end < 0)
        return buf.length > limits.maxHeadBytes ? fail(431)
            : HeadResult(ParseStatus.incomplete);
    if (end + 4 > limits.maxHeadBytes)
        return fail(431);

    const(char)[] head = buf[0 .. end + 2]; // includes the CRLF of the last line
    size_t p = 0;
    req.protocol = Protocol.http1; // `req` may be reused from an HTTP/2 stream
    req.connectProtocol = null;

    // ---- request line: METHOD SP target SP HTTP/1.x CRLF
    size_t s = p;
    while (p < head.length && head[p] != ' ')
        p++;
    if (p == head.length || p == s)
        return fail(400);
    req.method = parseMethod(head[s .. p]);
    if (req.method == Method.unknown)
        return fail(501);
    p++;

    s = p;
    while (p < head.length && head[p] != ' ' && head[p] != '\r')
        p++;
    if (p == head.length || head[p] != ' ' || p == s)
        return fail(400);
    req.target = head[s .. p];
    if (req.target.length > limits.maxTargetBytes)
        return fail(414);
    if (req.target[0] != '/' && !(req.method == Method.OPTIONS && req.target == "*"))
        return fail(400); // origin-form only in the MVP
    foreach (char c; req.target)
        if (c <= ' ' || c == 0x7f)
            return fail(400);
    splitTarget(req.target, req.path, req.query);
    p++;

    // "HTTP/" digit "." digit CRLF: wrong format = 400; a version that is not 1.0/1.1 = 505
    if (p + 10 > head.length || head[p .. p + 5] != "HTTP/" || head[p + 6] != '.'
        || head[p + 5] < '0' || head[p + 5] > '9' || head[p + 7] < '0' || head[p + 7] > '9'
        || head[p + 8 .. p + 10] != "\r\n")
        return fail(400);
    if (head[p + 5] != '1')
        return fail(505);
    immutable char minor = head[p + 7];
    if (minor != '0' && minor != '1')
        return fail(505);
    req.keepAlive = minor == '1';
    req.http11 = minor == '1';
    p += 10;

    // ---- headers
    size_t n = 0;
    bool sawLength = false, sawTE = false;
    int badTE = 0;
    size_t contentLength = 0;
    while (p < head.length)
    {
        if (head[p] == ' ' || head[p] == '\t')
            return fail(400); // obs-fold is forbidden (RFC 9112 §5.2)
        s = p;
        while (p < head.length && head[p] != ':' && head[p] != '\r')
        {
            if (!isTchar(head[p]))
                return fail(400);
            p++;
        }
        if (p == head.length || head[p] != ':' || p == s)
            return fail(400);
        auto name = head[s .. p];
        p++;
        while (p < head.length && (head[p] == ' ' || head[p] == '\t'))
            p++;
        s = p;
        while (p < head.length && head[p] != '\r')
        {
            if (head[p] == '\n' || head[p] == 0)
                return fail(400);
            p++;
        }
        size_t e = p;
        while (e > s && (head[e - 1] == ' ' || head[e - 1] == '\t'))
            e--;
        auto value = head[s .. e];
        if (p + 1 >= head.length || head[p + 1] != '\n')
            return fail(400);
        p += 2;

        if (n == headerStore.length)
            return fail(431);
        headerStore[n++] = HeaderField(name, value);

        if (equalsIgnoreCase(name, "content-length"))
        {
            size_t v = 0;
            if (value.length == 0 || value.length > 18)
                return fail(400);
            foreach (char c; value)
            {
                if (c < '0' || c > '9')
                    return fail(400);
                v = v * 10 + (c - '0');
            }
            if (sawLength && v != contentLength)
                return fail(400); // conflicting values: possible smuggling
            sawLength = true;
            contentLength = v;
        }
        else if (equalsIgnoreCase(name, "transfer-encoding"))
        {
            // `chunked` as the only coding. A second header, or a list ("chunked, identity", "gzip, chunked"), is refused: the
            // ambiguity between this parser and a proxy in front of it is what request smuggling lives on.
            if (sawTE)
                return fail(400);
            sawTE = true;
            if (!equalsIgnoreCase(value, "chunked"))
                badTE = value.length == 0 ? 400 : 501; // decided after the loop: Content-Length next to it is a 400 first
        }
        else if (equalsIgnoreCase(name, "expect"))
        {
            if (!equalsIgnoreCase(value, "100-continue"))
                return fail(417);
        }
        else if (equalsIgnoreCase(name, "connection"))
        {
            if (equalsIgnoreCase(value, "close"))
                req.keepAlive = false;
            else if (equalsIgnoreCase(value, "keep-alive"))
                req.keepAlive = true;
        }
    }

    if (sawTE && sawLength)
        return fail(400); // RFC 9112 §6.1: reject to avoid smuggling
    if (badTE)
        return fail(badTE);
    if (sawTE && !req.http11)
        return fail(400); // HTTP/1.0 has no chunked coding (RFC 9112 §6.1)
    if (contentLength > limits.maxBodyBytes)
        return fail(413);

    req.headers = headerStore[0 .. n];
    return HeadResult(ParseStatus.complete, end + 4, contentLength, sawTE, 0);
}

unittest
{
    auto store = new HeaderField[32]; // (heap: the parser keeps views into the store in `r`, which a stack array cannot lend)
    Request r;
    string raw = "PUT /users/42?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 7\r\n"
        ~ "Authorization:  Bearer t  \r\n\r\n{\"a\":1}";
    auto h = parseRequestHead(raw, r, store[]);
    assert(h.status == ParseStatus.complete);
    assert(r.method == Method.PUT && r.path == "/users/42" && r.query == "x=1");
    assert(r.header("authorization") == "Bearer t");
    assert(h.contentLength == 7 && raw[h.headLength .. $] == "{\"a\":1}");
    assert(r.keepAlive);

    // incomplete
    assert(parseRequestHead("GET / HTTP/1.1\r\nHost: a\r\n", r, store[]).status == ParseStatus.incomplete);
    // smuggling: CL + TE
    auto bad = parseRequestHead("POST / HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
        r, store[]);
    assert(bad.status == ParseStatus.error && bad.errorStatus == 400);
    // obs-fold
    assert(parseRequestHead("GET / HTTP/1.1\r\nA: b\r\n c\r\n\r\n", r, store[]).errorStatus == 400);
    // version
    assert(parseRequestHead("GET / HTTP/2.0\r\n\r\n", r, store[]).errorStatus == 505);
    // HTTP/1.0 without keep-alive closes
    parseRequestHead("GET / HTTP/1.0\r\n\r\n", r, store[]);
    assert(!r.keepAlive);
    // a Request reused after an HTTP/2 stream is HTTP/1 again
    r.protocol = Protocol.http2;
    parseRequestHead("GET / HTTP/1.1\r\n\r\n", r, store[]);
    assert(r.protocol == Protocol.http1);
}
