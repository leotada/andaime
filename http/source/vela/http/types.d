/// HTTP vocabulary shared between `vela:engine` and `vela:web`.
/// Nothing here makes syscalls or allocates on the GC.
module vela.http.types;

@safe:

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

/// View of an already-parsed request. Owns no memory.
struct Request
{
    Method method;
    const(char)[] target; /// path?query exactly as received
    const(char)[] path;   /// without the query, still percent-encoded
    const(char)[] query;  /// without the '?', still percent-encoded
    HeaderField[] headers;
    const(ubyte)[] body;
    bool keepAlive = true;

    /// First header with that name (case-insensitive) or `null`.
    const(char)[] header(scope const(char)[] name) const pure nothrow @nogc
    {
        foreach (ref h; headers)
            if (equalsIgnoreCase(h.name, name))
                return h.value;
        return null;
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
        case 200: return "OK";
        case 201: return "Created";
        case 202: return "Accepted";
        case 100: return "Continue";
        case 204: return "No Content";
        case 301: return "Moved Permanently";
        case 302: return "Found";
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
        case 413: return "Content Too Large";
        case 414: return "URI Too Long";
        case 415: return "Unsupported Media Type";
        case 417: return "Expectation Failed";
        case 422: return "Unprocessable Content";
        case 429: return "Too Many Requests";
        case 431: return "Request Header Fields Too Large";
        case 500: return "Internal Server Error";
        case 501: return "Not Implemented";
        case 503: return "Service Unavailable";
        case 505: return "HTTP Version Not Supported";
        default: return "Unknown";
    }
}

unittest
{
    Request r;
    splitTarget("/users?limit=10&name=ana&flag", r.path, r.query);
    assert(r.path == "/users");
    const(char)[] v;
    assert(r.rawQueryParam("limit", v) && v == "10");
    assert(r.rawQueryParam("name", v) && v == "ana");
    assert(r.rawQueryParam("flag", v) && v == "");
    assert(!r.rawQueryParam("nope", v));
    assert(parseMethod("PATCH") == Method.PATCH);
    assert(parseMethod("BREW") == Method.unknown);
}
