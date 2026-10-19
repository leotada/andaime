/// `Accept` matching, for the answers the engine writes by itself (`ErrorBody.accept`), and a header lookup in raw
/// request bytes for when the head could not be parsed. No allocation.
module andaime.http.accept 2025;

@safe:

import andaime.http.types : equalsIgnoreCase;

/// True when a request whose `Accept` header is `accept` takes `mediaType` (`application/json`, `text/*`, `*/*`).
/// An empty or missing header accepts anything (RFC 9110, 12.5.1). Parameters are ignored, except `q=0`, which refuses
/// the range when it names the type exactly (`text/html;q=0, */*` refuses HTML and takes the rest).
bool acceptsMediaType(scope const(char)[] accept, scope const(char)[] mediaType) pure nothrow @nogc
{
    return acceptRank(accept, mediaType) != AcceptRank.refused;
}

/// How a request takes a media type: not at all, through a wildcard on either side (`*/*`, `text/*`, a missing
/// header), or by naming it. Lets a server prefer what the client asked for by name over what it merely tolerates.
enum AcceptRank : ubyte
{
    refused,
    wildcard,
    named,
}

/// ditto
AcceptRank acceptRank(scope const(char)[] accept, scope const(char)[] mediaType) pure nothrow @nogc
{
    accept = trim(accept);
    if (accept.length == 0 || trim(mediaType).length == 0)
        return AcceptRank.wildcard;
    auto mt = mainType(mediaType), ms = subType(mediaType);
    bool taken, named, refused;
    size_t i;
    while (i <= accept.length)
    {
        size_t j = i;
        while (j < accept.length && accept[j] != ',')
            j++;
        auto part = accept[i .. j];
        i = j + 1;
        size_t semi;
        while (semi < part.length && part[semi] != ';')
            semi++;
        auto range = trim(part[0 .. semi]);
        if (range.length == 0)
            continue;
        auto rt = mainType(range), rs = subType(range);
        if (!matches(rt, mt) || !matches(rs, ms))
            continue;
        if (qIsZero(part[semi .. $]))
        {
            if (rt != "*" && rs != "*")
                refused = true;
        }
        else
        {
            taken = true;
            named |= rt != "*" && rs != "*" && mt != "*" && ms != "*";
        }
    }
    if (!taken || refused)
        return AcceptRank.refused;
    return named ? AcceptRank.named : AcceptRank.wildcard;
}

/// The value of the first header `name` in the raw bytes of a request head, trimmed, or null. Looks only at the bytes
/// given and stops at the blank line that ends the head; the request line is skipped. For a head the parser rejected,
/// so it accepts what the parser would not and must never be used to serve a request.
const(char)[] rawHeaderValue(return scope const(char)[] bytes, scope const(char)[] name) pure nothrow @nogc
{
    size_t i;
    while (i < bytes.length && bytes[i] != '\n') // the request line
        i++;
    i++;
    while (i < bytes.length)
    {
        size_t end = i;
        while (end < bytes.length && bytes[end] != '\n')
            end++;
        auto line = bytes[i .. end];
        foreach (k, c; line)
            if (c == '\r') // the line ends at its first CR (a bare CR inside it too: this head is malformed anyway)
            {
                line = line[0 .. k];
                break;
            }
        if (line.length == 0)
            return null; // end of the head
        size_t colon;
        while (colon < line.length && line[colon] != ':')
            colon++;
        if (colon < line.length && equalsIgnoreCase(trim(line[0 .. colon]), name))
            return trim(line[colon + 1 .. $]);
        i = end + 1;
    }
    return null;
}

private bool matches(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    return a == "*" || b == "*" || equalsIgnoreCase(a, b);
}

/// `text` of `text/html`.
private const(char)[] mainType(return scope const(char)[] s) pure nothrow @nogc
{
    size_t k;
    while (k < s.length && s[k] != '/')
        k++;
    return trim(s[0 .. k]);
}

/// `html` of `text/html`; `*` when there is no subtype.
private const(char)[] subType(return scope const(char)[] s) pure nothrow @nogc
{
    size_t k;
    while (k < s.length && s[k] != '/')
        k++;
    return k < s.length ? trim(s[k + 1 .. $]) : "*";
}

/// `params` is `;q=0;level=1`: true when a `q` parameter is zero (`0`, `0.0`, `0.000`).
private bool qIsZero(scope const(char)[] params) pure nothrow @nogc
{
    size_t i;
    while (i < params.length)
    {
        size_t j = i + 1;
        while (j < params.length && params[j] != ';')
            j++;
        auto p = trim(params[i + 1 .. j]);
        if (p.length >= 2 && (p[0] == 'q' || p[0] == 'Q') && trim(p[1 .. $]).length && trim(p[1 .. $])[0] == '=')
        {
            auto v = trim(trim(p[1 .. $])[1 .. $]);
            if (v.length == 0 || v[0] != '0')
                return false;
            foreach (c; v[1 .. $])
                if (c != '.' && c != '0')
                    return false;
            return true;
        }
        i = j;
    }
    return false;
}

private const(char)[] trim(return scope const(char)[] s) pure nothrow @nogc
{
    while (s.length && (s[0] == ' ' || s[0] == '\t'))
        s = s[1 .. $];
    while (s.length && (s[$ - 1] == ' ' || s[$ - 1] == '\t'))
        s = s[0 .. $ - 1];
    return s;
}

@safe unittest
{
    assert(acceptsMediaType(null, "application/json"));
    assert(acceptsMediaType("application/json", "application/json"));
    assert(acceptsMediaType("Application/JSON; charset=utf-8", "application/json"));
    assert(!acceptsMediaType("text/html", "application/json"));
    assert(acceptsMediaType("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "text/html"));
    assert(acceptsMediaType("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "application/json"));
    assert(acceptsMediaType("text/*", "text/plain"));
    assert(!acceptsMediaType("text/*", "application/json"));
    assert(acceptsMediaType("application/json", "*/*"), "an entry for */* takes any request");
    assert(!acceptsMediaType("text/html;q=0, */*", "text/html"));
    assert(acceptsMediaType("text/html;q=0, */*", "application/json"));
    assert(!acceptsMediaType("application/json;q=0.000", "application/json"));
    assert(acceptsMediaType("application/json;q=0.5", "application/json"));
    assert(!acceptsMediaType(" , ;q=1", "text/plain"));

    enum browser = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8";
    assert(acceptRank(browser, "text/html") == AcceptRank.named);
    assert(acceptRank(browser, "application/json") == AcceptRank.wildcard);
    assert(acceptRank(null, "text/html") == AcceptRank.wildcard);
    assert(acceptRank("application/json", "*/*") == AcceptRank.wildcard);
    assert(acceptRank("text/*", "text/html") == AcceptRank.wildcard);
    assert(acceptRank("image/png", "text/html") == AcceptRank.refused);

    assert(rawHeaderValue("GET / HTTP/1.1\r\nHost: x\r\nAccept:  text/html \r\n\r\n", "accept") == "text/html");
    assert(rawHeaderValue("GET / HTTP/1.1\r\nHost: x\r\n\r\nAccept: text/html\r\n", "accept") is null, "stops at the blank line");
    assert(rawHeaderValue("GET / HTTP/1.1\nACCEPT: a/b\n", "accept") == "a/b");
    assert(rawHeaderValue("Accept: a/b", "accept") is null, "the first line is the request line");
    assert(rawHeaderValue("", "accept") is null);
    assert(rawHeaderValue("GET / HTTP/1.1\r\nbroken line\r\nAccept: x/y", "accept") == "x/y");
}
