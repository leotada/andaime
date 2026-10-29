/// HTTP vocabulary shared between `andaime:engine` and `andaime:web`.
/// Nothing here makes syscalls or allocates on the GC.
module andaime.http.types 2025;

@safe:

import andaime.http.ip : IpAddress;

enum Method : ubyte { GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS, unknown }

/// Number of real methods (excludes `unknown`).
enum size_t methodCount = Method.unknown;

Method parseMethod(scope const(char)[] s) pure nothrow @nogc
{
    switch (s)
    {
        case "GET": return Method.GET;
        case "HEAD": return Method.HEAD;
        case "POST": return Method.POST;
        case "PUT": return Method.PUT;
        case "PATCH": return Method.PATCH;
        case "DELETE": return Method.DELETE;
        case "OPTIONS": return Method.OPTIONS;
        default: return Method.unknown;
    }
}

string methodName(Method m) pure nothrow @nogc
{
    static immutable string[methodCount + 1] names =
        ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "UNKNOWN"];
    return names[m];
}

/// Name/value pair. In the request, the slices point into the network buffer
/// (zero-copy) and are only valid while the request is being processed.
struct HeaderField
{
    const(char)[] name;
    const(char)[] value;
}

bool equalsIgnoreCase(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z') x += 32;
        if (y >= 'A' && y <= 'Z') y += 32;
        if (x != y)
            return false;
    }
    return true;
}

/// Wire protocol a request arrived on. Handlers rarely need it: the response is the same.
enum Protocol : ubyte { http1, http2 }

/// Iterator over the values of one key in a query string (see `Request.queryValues`).
struct QueryValues
{
    private const(char)[] rest;
    private const(char)[] key;
    private const(char)[] cur;
    private bool has;

    this(const(char)[] query, const(char)[] key) pure nothrow @nogc
    {
        rest = query;
        this.key = key;
        advance();
    }

    bool empty() const pure nothrow @nogc => !has;
    const(char)[] front() const pure nothrow @nogc => cur;

    void popFront() pure nothrow @nogc
    {
        advance();
    }

    private void advance() pure nothrow @nogc
    {
        has = false;
        while (rest.length)
        {
            size_t amp = 0;
            while (amp < rest.length && rest[amp] != '&')
                amp++;
            auto pair = rest[0 .. amp];
            rest = amp < rest.length ? rest[amp + 1 .. $] : null;
            size_t eq = 0;
            while (eq < pair.length && pair[eq] != '=')
                eq++;
            if (pair[0 .. eq] == key)
            {
                cur = eq < pair.length ? pair[eq + 1 .. $] : pair[$ .. $];
                has = true;
                return;
            }
        }
    }
}

/// The part of a request body that has not been received yet: the engine hands a large HTTP/1.1 body to the handler
/// this way instead of buffering it whole (`ServerConfig.bufferBodyBytes`). Implemented by the engine's request fiber.
interface BodyReader
{
    /// Copies up to `into.length` bytes of the body into `into` and returns how many; 0 means the body ended. Suspends
    /// the fiber while the client is sending. The engine throws `RequestCancelled` when the client goes away or stops
    /// sending for `headerTimeoutMs`.
    size_t read(scope ubyte[] into);

    /// Bytes of the body not read yet (the declared `Content-Length` minus what `read` returned).
    ulong unread() const;
}

/// View of an already-parsed request. Owns no memory.
struct Request
{
    Method method;
    Protocol protocol;
    const(char)[] target; /// path?query exactly as received
    const(char)[] path;   /// without the query, still percent-encoded
    const(char)[] query;  /// without the '?', still percent-encoded
    HeaderField[] headers;
    /// The whole body, when it was buffered. Empty while `bodyReader` is set.
    const(ubyte)[] body;
    /// Set by the engine for an HTTP/1.1 body larger than `ServerConfig.bufferBodyBytes`: the body has not been
    /// received yet and is read through it, once. The web layer reads it whole into `body` for every route except
    /// those that take it as a stream (`BodyStream`, a form with `SpooledFile`). Null otherwise.
    BodyReader bodyReader;
    bool keepAlive = true;
    /// HTTP/1.1 (or HTTP/2). False for an HTTP/1.0 client, which cannot be sent a chunked body.
    bool http11 = true;
    /// HTTP/2 only: the `:protocol` of an extended CONNECT (RFC 8441), i.e. "websocket"; null otherwise. Such a request
    /// is presented as a GET (`method`) so that it reaches the `ws!` route of its path.
    const(char)[] connectProtocol;
    /// The TCP peer. Set by the engine for both HTTP/1 and HTTP/2 (the address does not come from the bytes, so neither the
    /// parser nor the HTTP/2 session sets it). Behind a proxy use `ctx.clientIp()` for the real client.
    IpAddress peer;

    /// First header with that name (case-insensitive) or `null`.
    const(char)[] header(scope const(char)[] name) const pure nothrow @nogc
    {
        foreach (ref h; headers)
            if (equalsIgnoreCase(h.name, name))
                return h.value;
        return null;
    }

    /// Every raw (still encoded) value of `name` in the query string, in order: `?tag=a&tag=b` gives "a", "b". A key
    /// without `=` has the empty value. Allocation-free; use it like a range (`empty`, `front`, `popFront`).
    QueryValues queryValues(const(char)[] name) const pure nothrow @nogc
    {
        return QueryValues(query, name);
    }

    /// Raw (still encoded) value of the first `name` in the query string.
    bool rawQueryParam(scope const(char)[] name, out const(char)[] value) const pure nothrow @nogc
    {
        const(char)[] q = query;
        while (q.length)
        {
            size_t amp = 0;
            while (amp < q.length && q[amp] != '&')
                amp++;
            auto pair = q[0 .. amp];
            q = amp < q.length ? q[amp + 1 .. $] : null;
            size_t eq = 0;
            while (eq < pair.length && pair[eq] != '=')
                eq++;
            if (pair[0 .. eq] == name)
            {
                value = eq < pair.length ? pair[eq + 1 .. $] : pair[$ .. $];
                return true;
            }
        }
        return false;
    }
}

/// Splits `target` into path and query (without allocating).
void splitTarget(const(char)[] target, out const(char)[] path, out const(char)[] query) pure nothrow @nogc
{
    foreach (i, c; target)
    {
        if (c == '?')
        {
            path = target[0 .. i];
            query = target[i + 1 .. $];
            return;
        }
    }
    path = target;
}

string statusText(int code) pure nothrow @nogc
{
    switch (code)
    {
        case 100: return "Continue";
        case 101: return "Switching Protocols";
        case 200: return "OK";
        case 201: return "Created";
        case 202: return "Accepted";
        case 204: return "No Content";
        case 206: return "Partial Content";
        case 301: return "Moved Permanently";
        case 302: return "Found";
        case 303: return "See Other";
        case 304: return "Not Modified";
        case 307: return "Temporary Redirect";
        case 308: return "Permanent Redirect";
        case 400: return "Bad Request";
        case 401: return "Unauthorized";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 405: return "Method Not Allowed";
        case 408: return "Request Timeout";
        case 409: return "Conflict";
        case 410: return "Gone";
        case 411: return "Length Required";
        case 412: return "Precondition Failed";
        case 413: return "Content Too Large";
        case 414: return "URI Too Long";
        case 415: return "Unsupported Media Type";
        case 416: return "Range Not Satisfiable";
        case 417: return "Expectation Failed";
        case 422: return "Unprocessable Content";
        case 426: return "Upgrade Required";
        case 428: return "Precondition Required";
        case 429: return "Too Many Requests";
        case 431: return "Request Header Fields Too Large";
        case 451: return "Unavailable For Legal Reasons";
        case 500: return "Internal Server Error";
        case 501: return "Not Implemented";
        case 502: return "Bad Gateway";
        case 503: return "Service Unavailable";
        case 504: return "Gateway Timeout";
        case 505: return "HTTP Version Not Supported";
        default: return "Unknown";
    }
}

unittest
{
    assert(statusText(502) == "Bad Gateway" && statusText(504) == "Gateway Timeout");
    assert(statusText(303) == "See Other" && statusText(299) == "Unknown");
}

/// RFC 9110 `tchar`: the characters allowed in a header field name (and in a method).
bool isTchar(char c) pure nothrow @nogc @safe
{
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return true;
    switch (c)
    {
        case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
            return true;
        default:
            return false;
    }
}

/// A non-empty header field name made of token characters only.
bool isValidHeaderName(scope const(char)[] name) pure nothrow @nogc @safe
{
    if (name.length == 0)
        return false;
    foreach (char c; name)
        if (!isTchar(c))
            return false;
    return true;
}

/// A header field value: HTAB, 0x20-0x7E and 0x80-0xFF only. Rejects CR, LF, NUL and every other control character,
/// which is what stops response splitting.
bool isValidHeaderValue(scope const(char)[] value) pure nothrow @nogc @safe
{
    foreach (char c; value)
        if ((c < 0x20 && c != '\t') || c == 0x7F)
            return false;
    return true;
}

unittest
{
    assert(isValidHeaderName("X-Request-Id") && !isValidHeaderName("") && !isValidHeaderName("Bad Name")
        && !isValidHeaderName("A:B") && !isValidHeaderName("A\r\nB"));
    assert(isValidHeaderValue("text/html; charset=utf-8") && isValidHeaderValue("tab\there") && isValidHeaderValue("caf\xc3\xa9"));
    assert(!isValidHeaderValue("a\r\nSet-Cookie: x") && !isValidHeaderValue("a\nb") && !isValidHeaderValue("a\0b")
        && !isValidHeaderValue("a\x7f"));
}

unittest
{
    Request r;
    splitTarget("/users?limit=10&name=ana&flag", r.path, r.query);
    assert(r.path == "/users");
    const(char)[] v;
    {
        Request many;
        splitTarget("/x?tag=a&other=1&tag=b%20c&tag&tag=", many.path, many.query);
        string[] got;
        foreach (val; many.queryValues("tag"))
            got ~= val.idup;
        assert(got == ["a", "b%20c", "", ""]);
        assert(many.queryValues("none").empty && many.queryValues("tag").front == "a");
    }
    assert(r.rawQueryParam("limit", v) && v == "10");
    assert(r.rawQueryParam("name", v) && v == "ana");
    assert(r.rawQueryParam("flag", v) && v == "");
    assert(!r.rawQueryParam("nope", v));
    assert(parseMethod("PATCH") == Method.PATCH);
    assert(parseMethod("BREW") == Method.unknown);
}
