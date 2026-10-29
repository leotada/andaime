/// `multipart/form-data` (RFC 7578, framing from RFC 2046). Pure: no I/O. The body is already buffered, so this is a
/// one-shot scan, not an incremental decoder.
///
/// Part names, filenames and content types are copies. `MultipartPart.data` is a slice of the input body. A part is
/// rejected when the body is truncated, the framing is wrong, or a limit is exceeded: 128 parts, 8 KiB of headers per
/// part, a name of 256 bytes, a filename of 1024 bytes.
module andaime.http.multipart 2025;

@safe:

import andaime.http.types : equalsIgnoreCase, isTchar;
import andaime.http.utf8 : validUtf8;

enum size_t maxMultipartParts = 128;
enum size_t maxMultipartHeaderBytes = 8 * 1024;
enum size_t maxMultipartNameBytes = 256;
enum size_t maxMultipartFilenameBytes = 1024;

enum FormCoding : ubyte
{
    other,      /// not a form content type
    urlEncoded, /// application/x-www-form-urlencoded
    multipart,  /// multipart/form-data
}

struct FormContentType
{
    FormCoding coding;
    string boundary; /// set when `coding` is `multipart`
}

/// One part. `filename` is null when the part has no filename parameter (a text field). `contentType` is the
/// type/subtype only, null when the part sent no Content-Type. `charset` is lowercased, null when absent.
struct MultipartPart
{
    string name;
    string filename;
    string contentType;
    string charset;
    const(ubyte)[] data;
}

private enum string malformedBody = "malformed multipart body";
private enum string tooManyParts = "multipart body has too many parts";
private enum string noBoundary = "multipart body has no boundary";
private enum string badBoundary = "invalid multipart boundary";

/// Classifies a Content-Type header. `error` is set only when the type is `multipart/form-data` but the boundary is
/// missing, duplicated or not a boundary token; any other header leaves `error` null and `result.coding` as `other`
/// or `urlEncoded`.
void classifyFormContentType(scope const(char)[] header, out FormContentType result, out string error)
{
    result = FormContentType.init;
    error = null;
    if (header.length == 0)
        return;
    size_t i;
    skipOws(header, i);
    const(char)[] typ, sub;
    if (!readToken(header, i, typ) || i >= header.length || header[i++] != '/' || !readToken(header, i, sub))
        return;
    immutable multi = equalsIgnoreCase(typ, "multipart") && equalsIgnoreCase(sub, "form-data");
    immutable url = equalsIgnoreCase(typ, "application") && equalsIgnoreCase(sub, "x-www-form-urlencoded");
    if (!multi && !url)
        return;
    if (i < header.length && header[i] != ';' && header[i] != ' ' && header[i] != '\t')
        return;
    if (url)
    {
        result.coding = FormCoding.urlEncoded;
        return;
    }
    bool sawBoundary;
    while (true)
    {
        skipOws(header, i);
        if (i >= header.length)
            break;
        if (header[i++] != ';')
        {
            error = malformedBody;
            return;
        }
        skipOws(header, i);
        const(char)[] key;
        if (!readToken(header, i, key))
        {
            error = malformedBody;
            return;
        }
        skipOws(header, i);
        if (i >= header.length || header[i++] != '=')
        {
            error = malformedBody;
            return;
        }
        skipOws(header, i);
        string val;
        if (!readParamValue(header, i, val))
        {
            error = malformedBody;
            return;
        }
        if (equalsIgnoreCase(key, "boundary"))
        {
            if (sawBoundary)
            {
                error = malformedBody;
                return;
            }
            sawBoundary = true;
            if (!validBoundary(val))
            {
                error = badBoundary;
                return;
            }
            result.boundary = val;
        }
    }
    if (!sawBoundary)
    {
        error = noBoundary;
        return;
    }
    result.coding = FormCoding.multipart;
}

/// Parses `body` as multipart/form-data. Returns null on success. `boundary` is the raw boundary parameter, without
/// the leading `--`.
string parseMultipart(const(ubyte)[] body, scope const(char)[] boundary, out MultipartPart[] parts)
{
    parts = null;
    if (!validBoundary(boundary))
        return badBoundary;
    ptrdiff_t at = findFirst(body, boundary);
    if (at < 0)
        return malformedBody;
    size_t p = cast(size_t) at + 2 + boundary.length;
    while (true)
    {
        immutable tail = readTail(body, p);
        if (tail == Tail.close)
            return null;
        if (tail == Tail.bad)
            return malformedBody;
        if (parts.length >= maxMultipartParts)
            return tooManyParts;
        string error;
        if (!readPart(body, boundary, p, parts, error))
            return error;
    }
}

/// What `MultipartScanner.next` found.
enum MultipartEvent : ubyte
{
    needMore, /// nothing more can be decided without more bytes (or the body is over: see `eof`)
    part,     /// a part starts: its head is in `part` (no data)
    data,     /// bytes of the current part's content, in `data`
    partEnd,  /// the current part ended
    done,     /// the closing delimiter: there are no more parts (what follows it is the epilogue)
    error,    /// the body is malformed or over a limit: `MultipartScanner.error`
}

/// `multipart/form-data` decoded incrementally, for a body that arrives in pieces: the same grammar and limits as
/// `parseMultipart`, as a stream of events. The caller keeps a window of the bytes it received and has not consumed
/// yet, and calls `next` with it; `next` reports how many bytes of the window it used, and the caller drops them
/// before the next call. A part's head must fit in the window (it is at most `maxMultipartHeaderBytes`); its content
/// comes out in slices of the window, so a window of a few KiB decodes a body of any size.
///
///     MultipartScanner s = MultipartScanner(boundary);
///     for (;;) {
///         auto ev = s.next(window, eof, used, part, data);
///         window = window[used .. $];       // (the caller compacts and refills its buffer here)
///         if (ev == MultipartEvent.needMore) { if (eof) break; read more; continue; }
///         ...
///     }
struct MultipartScanner
{
    /// Set when `next` returned `MultipartEvent.error`.
    string error;

    private enum State : ubyte { preamble, tail, closing, tailSpace, headers, data, finished, failed }

    private string boundary;
    private State state;
    private bool started;  /// some bytes were consumed (a dash-boundary at window position 0 is then not at a line start)
    private size_t count;  /// parts seen

    this(string boundary)
    {
        this.boundary = boundary;
        if (!validBoundary(boundary))
            fail(badBoundary);
    }

    /// The next event from `window` (the bytes not consumed yet; `eof`: no more will come). `consumed` is how much of
    /// `window` it used. `data` is a slice of `window`, valid until the caller drops or overwrites those bytes.
    MultipartEvent next(const(ubyte)[] window, bool eof, out size_t consumed, ref MultipartPart part,
        out const(ubyte)[] data)
    {
        for (;;)
        {
            size_t used;
            immutable ev = step(window[consumed .. $], eof, used, part, data);
            consumed += used;
            if (ev != again)
                return ev;
        }
    }

    /// Internal: the state changed; `next` goes on with the rest of the window.
    private enum MultipartEvent again = cast(MultipartEvent) 0xFF;

    private MultipartEvent step(const(ubyte)[] window, bool eof, out size_t consumed, ref MultipartPart part,
        out const(ubyte)[] data)
    {
        final switch (state)
        {
            case State.preamble: return preamble(window, eof, consumed);
            case State.tail: return tail(window, eof, consumed);
            case State.closing: return closing(window, eof, consumed);
            case State.tailSpace: return tailSpace(window, eof, consumed);
            case State.headers: return headers(window, eof, consumed, part);
            case State.data: return content(window, eof, consumed, data);
            case State.finished: return MultipartEvent.done;
            case State.failed: return MultipartEvent.error;
        }
    }

    private MultipartEvent fail(string why)
    {
        error = why;
        state = State.failed;
        return MultipartEvent.error;
    }

    private MultipartEvent moreOr(bool eof) => eof ? fail(malformedBody) : MultipartEvent.needMore;

    /// Skips everything before the first dash-boundary at a line start.
    private MultipartEvent preamble(scope const(ubyte)[] w, bool eof, out size_t consumed)
    {
        for (size_t p = 0; p < w.length; p++)
        {
            immutable atLine = (p == 0 && !started) || (p >= 2 && w[p - 2] == '\r' && w[p - 1] == '\n');
            if (!atLine)
                continue;
            final switch (boundaryMatch(w, p, boundary, eof))
            {
                case Match.no:
                    break;
                case Match.yes:
                    consumed = p + 2 + boundary.length;
                    started = true;
                    state = State.tail;
                    return again;
                case Match.unknown:
                    return keepPreamble(w, p, consumed);
            }
        }
        if (eof)
            return fail(malformedBody);
        return keepPreamble(w, w.length, consumed);
    }

    /// Drops the preamble before `p`, keeping the two bytes that tell whether `p` starts a line.
    private MultipartEvent keepPreamble(scope const(ubyte)[] w, size_t p, out size_t consumed)
    {
        consumed = p > 2 ? p - 2 : 0;
        if (consumed)
            started = true;
        return MultipartEvent.needMore;
    }

    /// Right after a dash-boundary: `--` (the close delimiter) or optional whitespace and CRLF (another part).
    private MultipartEvent tail(scope const(ubyte)[] w, bool eof, out size_t consumed)
    {
        if (w.length == 0)
            return moreOr(eof);
        if (w[0] == '-')
        {
            if (w.length < 2)
                return moreOr(eof);
            if (w[1] == '-')
            {
                consumed = 2;
                state = State.closing;
                return again;
            }
        }
        state = State.tailSpace;
        return again;
    }

    private MultipartEvent closing(scope const(ubyte)[] w, bool eof, out size_t consumed)
    {
        size_t p;
        while (p < w.length && isLwsp(w[p]))
            p++;
        consumed = p;
        if (p == w.length)
        {
            if (!eof)
                return MultipartEvent.needMore;
        }
        else if (w[p] != '\r' || (p + 1 < w.length && w[p + 1] != '\n'))
            return fail(malformedBody);
        else if (p + 1 == w.length && !eof)
            return MultipartEvent.needMore;
        else if (p + 1 == w.length)
            return fail(malformedBody);
        state = State.finished;
        return MultipartEvent.done;
    }

    private MultipartEvent tailSpace(scope const(ubyte)[] w, bool eof, out size_t consumed)
    {
        size_t p;
        while (p < w.length && isLwsp(w[p]))
            p++;
        consumed = p;
        if (w.length - p < 2)
            return moreOr(eof);
        if (w[p] != '\r' || w[p + 1] != '\n')
            return fail(malformedBody);
        if (count >= maxMultipartParts)
            return fail(tooManyParts);
        consumed = p + 2;
        state = State.headers;
        return again;
    }

    /// A part's head, once its blank line is in the window.
    private MultipartEvent headers(const(ubyte)[] w, bool eof, out size_t consumed, ref MultipartPart part)
    {
        ptrdiff_t end = -1;
        if (w.length >= 2 && w[0] == '\r' && w[1] == '\n')
            end = 2;
        else
            foreach (p; 0 .. w.length < 4 ? 0 : w.length - 3)
                if (w[p] == '\r' && w[p + 1] == '\n' && w[p + 2] == '\r' && w[p + 3] == '\n')
                {
                    end = p + 4;
                    break;
                }
        if (end < 0)
        {
            if (w.length > maxMultipartHeaderBytes + 4)
                return fail(malformedBody);
            return moreOr(eof);
        }
        part = MultipartPart.init;
        size_t p;
        string why;
        if (!readPartHeaders(w[0 .. end], p, part, why))
            return fail(why);
        consumed = p;
        count++;
        state = State.data;
        return MultipartEvent.part;
    }

    /// The content up to the next delimiter (CRLF and a dash-boundary).
    private MultipartEvent content(const(ubyte)[] w, bool eof, out size_t consumed, out const(ubyte)[] data)
    {
        for (size_t p = 0; p < w.length; p++)
        {
            if (w[p] != '\r')
                continue;
            if (p + 1 == w.length)
                return eof ? fail(malformedBody) : giveData(w, p, consumed, data);
            if (w[p + 1] != '\n')
                continue;
            final switch (boundaryMatch(w, p + 2, boundary, eof))
            {
                case Match.no:
                    break;
                case Match.yes:
                    if (p > 0)
                        return giveData(w, p, consumed, data);
                    consumed = 2 + 2 + boundary.length;
                    state = State.tail;
                    return MultipartEvent.partEnd;
                case Match.unknown:
                    return giveData(w, p, consumed, data);
            }
        }
        if (eof)
            return fail(malformedBody);
        return giveData(w, w.length, consumed, data);
    }

    private static MultipartEvent giveData(const(ubyte)[] w, size_t n, out size_t consumed,
        out const(ubyte)[] data)
    {
        if (n == 0)
            return MultipartEvent.needMore;
        consumed = n;
        data = w[0 .. n];
        return MultipartEvent.data;
    }
}

private enum Match : ubyte { no, yes, unknown }

/// `boundaryAt` for a window that may end early: `unknown` when the bytes so far agree but the window ends before
/// the character that decides (and more bytes may come).
private Match boundaryMatch(scope const(ubyte)[] w, size_t p, scope const(char)[] boundary, bool eof) pure nothrow @nogc
{
    immutable need = 2 + boundary.length;
    immutable avail = p <= w.length ? w.length - p : 0;
    foreach (k; 0 .. avail < need ? avail : need)
    {
        immutable char want = k < 2 ? '-' : boundary[k - 2];
        if (w[p + k] != cast(ubyte) want)
            return Match.no;
    }
    if (avail <= need)
        return avail == need && eof ? Match.yes : (eof ? Match.no : Match.unknown);
    immutable ubyte n = w[p + need];
    return n == ' ' || n == '\t' || n == '\r' || n == '-' ? Match.yes : Match.no;
}

private enum Tail : ubyte { part, close, bad }

private bool isBoundaryChar(char c) pure nothrow @nogc
{
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return true;
    switch (c)
    {
        case '\'', '(', ')', '+', '_', ',', '-', '.', '/', ':', '=', '?':
            return true;
        default:
            return false;
    }
}

private bool validBoundary(scope const(char)[] b) pure nothrow @nogc
{
    if (b.length == 0 || b.length > 70)
        return false;
    foreach (char c; b)
        if (!isBoundaryChar(c))
            return false;
    return true;
}

private bool isLwsp(ubyte c) pure nothrow @nogc => c == ' ' || c == '\t';

private void skipOws(scope const(char)[] s, ref size_t i) pure nothrow @nogc
{
    while (i < s.length && (s[i] == ' ' || s[i] == '\t'))
        i++;
}

private bool readToken(scope const(char)[] s, ref size_t i, out const(char)[] tok) pure nothrow @nogc @trusted
{
    // @trusted: `tok` is a sub-slice of `s` that the caller keeps no longer than `s` (a local of the parsing function)
    immutable start = i;
    while (i < s.length && isTchar(s[i]))
        i++;
    if (i == start)
        return false;
    tok = s[start .. i];
    return true;
}

/// A quoted-string (unescaped) or, when unquoted, everything up to the next parameter separator.
private bool readParamValue(scope const(char)[] s, ref size_t i, out string value)
{
    if (i < s.length && s[i] == '"')
    {
        i++;
        char[] buf;
        bool esc;
        while (i < s.length)
        {
            immutable char c = s[i++];
            if (esc)
            {
                if (c < 0x20 || c == 0x7F)
                    return false;
                buf ~= c;
                esc = false;
                continue;
            }
            if (c == '\\')
            {
                esc = true;
                continue;
            }
            if (c == '"')
            {
                value = buf.idup;
                return true;
            }
            if (c < 0x20 && c != '\t' || c == 0x7F)
                return false;
            buf ~= c;
        }
        return false;
    }
    immutable start = i;
    size_t end = i;
    while (i < s.length && s[i] != ';')
    {
        i++;
        end = i;
    }
    while (end > start && (s[end - 1] == ' ' || s[end - 1] == '\t'))
        end--;
    value = s[start .. end].idup;
    return true;
}

private bool boundaryAt(scope const(ubyte)[] body, size_t p, scope const(char)[] boundary) pure nothrow @nogc
{
    if (p > body.length || body.length - p < 2 + boundary.length)
        return false;
    if (body[p] != '-' || body[p + 1] != '-')
        return false;
    foreach (k, char c; boundary)
        if (body[p + 2 + k] != cast(ubyte) c)
            return false;
    immutable after = p + 2 + boundary.length;
    if (after == body.length)
        return true;
    immutable ubyte n = body[after];
    return n == ' ' || n == '\t' || n == '\r' || n == '-';
}

private ptrdiff_t findFirst(scope const(ubyte)[] body, scope const(char)[] boundary) pure nothrow @nogc
{
    size_t p;
    while (p < body.length)
    {
        immutable atLine = p == 0 || (p >= 2 && body[p - 2] == '\r' && body[p - 1] == '\n');
        if (atLine && boundaryAt(body, p, boundary))
            return cast(ptrdiff_t) p;
        p++;
    }
    return -1;
}

/// Index of the CRLF that introduces the next dash-boundary, or -1.
private ptrdiff_t findNext(scope const(ubyte)[] body, size_t from, scope const(char)[] boundary) pure nothrow @nogc
{
    size_t p = from;
    while (p + 1 < body.length)
    {
        if (body[p] == '\r' && body[p + 1] == '\n' && boundaryAt(body, p + 2, boundary))
            return cast(ptrdiff_t) p;
        p++;
    }
    return -1;
}

private Tail readTail(scope const(ubyte)[] body, ref size_t p) pure nothrow @nogc
{
    if (p + 1 < body.length && body[p] == '-' && body[p + 1] == '-')
    {
        p += 2;
        while (p < body.length && isLwsp(body[p]))
            p++;
        if (p == body.length)
            return Tail.close;
        if (p + 1 < body.length && body[p] == '\r' && body[p + 1] == '\n')
            return Tail.close;
        return Tail.bad;
    }
    while (p < body.length && isLwsp(body[p]))
        p++;
    if (p + 1 >= body.length || body[p] != '\r' || body[p + 1] != '\n')
        return Tail.bad;
    p += 2;
    return Tail.part;
}

// sound: a header line is raw request bytes read as text; the result is decoded into owned strings before it escapes
private const(char)[] asText(return scope const(ubyte)[] b) pure nothrow @nogc @trusted
{
    return cast(const(char)[]) b;
}

private bool readPart(const(ubyte)[] body, scope const(char)[] boundary, ref size_t p,
    ref MultipartPart[] parts, out string error)
{
    MultipartPart part;
    if (!readPartHeaders(body, p, part, error))
        return false;
    immutable dataStart = p;
    immutable delim = findNext(body, dataStart, boundary);
    if (delim < 0)
    {
        error = malformedBody;
        return false;
    }
    part.data = body[dataStart .. cast(size_t) delim];
    immutable next = cast(size_t) delim + 2 + 2 + boundary.length;
    if (next <= p)
    {
        error = malformedBody;
        return false;
    }
    p = next;
    parts ~= part;
    return true;
}

/// Reads the header lines of a part from `p` through the blank line that ends them, into `part` (no data).
private bool readPartHeaders(const(ubyte)[] body, ref size_t p, ref MultipartPart part, out string error)
{
    immutable headerStart = p;
    bool sawDisp, sawType, sawCte;
    const(char)[] disposition, typeValue, cte;
    while (true)
    {
        if (p + 1 < body.length && body[p] == '\r' && body[p + 1] == '\n')
        {
            p += 2;
            if (p - headerStart > maxMultipartHeaderBytes)
            {
                error = malformedBody;
                return false;
            }
            break;
        }
        if (p < body.length && isLwsp(body[p]))
        {
            error = malformedBody; // no header folding
            return false;
        }
        immutable lineStart = p;
        while (p + 1 < body.length && !(body[p] == '\r' && body[p + 1] == '\n'))
            p++;
        if (p + 1 >= body.length)
        {
            error = malformedBody;
            return false;
        }
        immutable lineEnd = p;
        p += 2;
        if (p - headerStart > maxMultipartHeaderBytes)
        {
            error = malformedBody;
            return false;
        }
        auto line = asText(body[lineStart .. lineEnd]);
        ptrdiff_t colon = -1;
        foreach (k, char c; line)
            if (c == ':')
            {
                colon = k;
                break;
            }
        if (colon <= 0)
        {
            error = malformedBody;
            return false;
        }
        auto hname = line[0 .. colon];
        foreach (char c; hname)
            if (!isTchar(c))
            {
                error = malformedBody;
                return false;
            }
        auto hvalue = trimOws(line[colon + 1 .. $]);
        if (equalsIgnoreCase(hname, "content-disposition"))
        {
            if (sawDisp)
            {
                error = malformedBody;
                return false;
            }
            sawDisp = true;
            disposition = hvalue;
        }
        else if (equalsIgnoreCase(hname, "content-type"))
        {
            if (sawType)
            {
                error = malformedBody;
                return false;
            }
            sawType = true;
            typeValue = hvalue;
        }
        else if (equalsIgnoreCase(hname, "content-transfer-encoding"))
        {
            if (sawCte)
            {
                error = malformedBody;
                return false;
            }
            sawCte = true;
            cte = hvalue;
        }
    }
    if (!sawDisp)
    {
        error = malformedBody;
        return false;
    }
    if (!parseDisposition(disposition, part, error))
        return false;
    if (sawType && !parsePartType(typeValue, part, error))
        return false;
    if (sawCte && !parseCte(cte, error))
        return false;
    return true;
}

private const(char)[] trimOws(return scope const(char)[] s) pure nothrow @nogc
{
    size_t a, b = s.length;
    while (a < b && (s[a] == ' ' || s[a] == '\t'))
        a++;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t'))
        b--;
    return s[a .. b];
}

private bool parseDisposition(scope const(char)[] value, ref MultipartPart part, out string error)
{
    size_t i;
    skipOws(value, i);
    const(char)[] kind;
    if (!readToken(value, i, kind) || !equalsIgnoreCase(kind, "form-data"))
    {
        error = malformedBody;
        return false;
    }
    bool sawName, sawFile, sawStar, starOk;
    string star;
    while (true)
    {
        skipOws(value, i);
        if (i >= value.length)
            break;
        if (value[i++] != ';')
        {
            error = malformedBody;
            return false;
        }
        skipOws(value, i);
        const(char)[] key;
        if (!readToken(value, i, key))
        {
            error = malformedBody;
            return false;
        }
        skipOws(value, i);
        if (i >= value.length || value[i++] != '=')
        {
            error = malformedBody;
            return false;
        }
        skipOws(value, i);
        string val;
        if (!readParamValue(value, i, val))
        {
            error = malformedBody;
            return false;
        }
        if (equalsIgnoreCase(key, "name"))
        {
            if (sawName || !usableText(val, maxMultipartNameBytes, false))
            {
                error = malformedBody;
                return false;
            }
            sawName = true;
            part.name = val;
        }
        else if (equalsIgnoreCase(key, "filename"))
        {
            if (sawFile || !usableText(val, maxMultipartFilenameBytes, true))
            {
                error = malformedBody;
                return false;
            }
            sawFile = true;
            part.filename = val;
        }
        else if (equalsIgnoreCase(key, "filename*"))
        {
            if (sawStar)
            {
                error = malformedBody;
                return false;
            }
            sawStar = true;
            string decoded;
            if (decodeFilenameStar(val, decoded) && usableText(decoded, maxMultipartFilenameBytes, true))
            {
                starOk = true;
                star = decoded;
            }
        }
    }
    if (!sawName || (sawStar && !starOk && !sawFile))
    {
        error = malformedBody;
        return false;
    }
    if (starOk)
        part.filename = star;
    return true;
}

private bool usableText(scope const(char)[] s, size_t maxBytes, bool allowEmpty) pure nothrow @nogc
{
    if ((!allowEmpty && s.length == 0) || s.length > maxBytes || !validUtf8(s))
        return false;
    foreach (char c; s)
        if (c < 0x20 || c == 0x7F)
            return false;
    return true;
}

private bool decodeFilenameStar(scope const(char)[] raw, out string filename)
{
    ptrdiff_t q1 = -1;
    foreach (k, char c; raw)
        if (c == '\'')
        {
            q1 = cast(ptrdiff_t) k;
            break;
        }
    if (q1 <= 0)
        return false;
    auto charset = raw[0 .. q1];
    if (!equalsIgnoreCase(charset, "utf-8") && !equalsIgnoreCase(charset, "us-ascii"))
        return false;
    ptrdiff_t q2 = -1;
    foreach (k, char c; raw[q1 + 1 .. $])
        if (c == '\'')
        {
            q2 = q1 + 1 + cast(ptrdiff_t) k;
            break;
        }
    if (q2 < 0)
        return false;
    return percentDecodeUtf8(raw[q2 + 1 .. $], filename);
}

private int hexVal(char c) pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

private bool isAttrChar(char c) pure nothrow @nogc
{
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return true;
    switch (c)
    {
        case '!', '#', '$', '&', '+', '-', '.', '^', '_', '`', '|', '~':
            return true;
        default:
            return false;
    }
}

private bool percentDecodeUtf8(scope const(char)[] raw, out string filename)
{
    char[] o;
    for (size_t i = 0; i < raw.length; i++)
    {
        immutable char c = raw[i];
        if (c == '%')
        {
            if (i + 2 >= raw.length)
                return false;
            immutable h = hexVal(raw[i + 1]), l = hexVal(raw[i + 2]);
            if (h < 0 || l < 0)
                return false;
            o ~= cast(char) (h * 16 + l);
            i += 2;
        }
        else if (isAttrChar(c))
            o ~= c;
        else
            return false;
    }
    if (!validUtf8(o))
        return false;
    filename = o.idup;
    return true;
}

private bool parsePartType(scope const(char)[] value, ref MultipartPart part, out string error)
{
    size_t i;
    skipOws(value, i);
    const(char)[] typ, sub;
    if (!readToken(value, i, typ) || i >= value.length || value[i++] != '/' || !readToken(value, i, sub))
    {
        error = malformedBody;
        return false;
    }
    bool sawCharset;
    while (true)
    {
        skipOws(value, i);
        if (i >= value.length)
            break;
        if (value[i++] != ';')
        {
            error = malformedBody;
            return false;
        }
        skipOws(value, i);
        const(char)[] key;
        if (!readToken(value, i, key))
        {
            error = malformedBody;
            return false;
        }
        skipOws(value, i);
        if (i >= value.length || value[i++] != '=')
        {
            error = malformedBody;
            return false;
        }
        skipOws(value, i);
        string val;
        if (!readParamValue(value, i, val))
        {
            error = malformedBody;
            return false;
        }
        if (equalsIgnoreCase(key, "charset"))
        {
            if (sawCharset || val.length == 0)
            {
                error = malformedBody;
                return false;
            }
            sawCharset = true;
            part.charset = lowerCopy(val);
        }
    }
    part.contentType = value.idup;
    return true;
}

private string lowerCopy(scope const(char)[] s)
{
    char[] o = new char[s.length];
    foreach (k, char c; s)
        o[k] = (c >= 'A' && c <= 'Z') ? cast(char) (c + 32) : c;
    return o.idup;
}

private bool parseCte(scope const(char)[] value, out string error)
{
    size_t i;
    skipOws(value, i);
    const(char)[] tok;
    if (!readToken(value, i, tok))
    {
        error = malformedBody;
        return false;
    }
    skipOws(value, i);
    if (i != value.length || (!equalsIgnoreCase(tok, "7bit") && !equalsIgnoreCase(tok, "8bit")
            && !equalsIgnoreCase(tok, "binary")))
    {
        error = malformedBody;
        return false;
    }
    return true;
}

unittest
{
    FormContentType ct;
    string err;
    classifyFormContentType("application/x-www-form-urlencoded", ct, err);
    assert(err is null && ct.coding == FormCoding.urlEncoded);
    classifyFormContentType("application/x-www-form-urlencoded; charset=UTF-8", ct, err);
    assert(err is null && ct.coding == FormCoding.urlEncoded);
    classifyFormContentType("application/x-www-form-urlencodedX", ct, err);
    assert(err is null && ct.coding == FormCoding.other);
    classifyFormContentType("application/json", ct, err);
    assert(ct.coding == FormCoding.other);
    classifyFormContentType("multipart/form-data", ct, err);
    assert(err == noBoundary);
    classifyFormContentType("Multipart/Form-Data; Boundary=\"z\"", ct, err);
    assert(err is null && ct.coding == FormCoding.multipart && ct.boundary == "z");
    classifyFormContentType("multipart/form-data; boundary=\"a b\"", ct, err);
    assert(err == badBoundary);
    classifyFormContentType("multipart/form-data; boundary=abc; boundary=def", ct, err);
    assert(err == malformedBody);
    classifyFormContentType(null, ct, err);
    assert(err is null && ct.coding == FormCoding.other);

    MultipartPart[] parts;
    auto body = cast(const(ubyte)[]) ("preamble\r\n--z\r\n"
        ~ "Content-Disposition: form-data; name=\"title\"\r\n\r\n"
        ~ "hola\r\n"
        ~ "--z\r\n"
        ~ "Content-Disposition: form-data; name=\"file\"; filename=\"a b.txt\"\r\n"
        ~ "Content-Type: image/png\r\n"
        ~ "Content-Transfer-Encoding: binary\r\n\r\n"
        ~ "hi\r\n--z--\r\nepilogue");
    assert(parseMultipart(body, "z", parts) is null);
    assert(parts.length == 2);
    assert(parts[0].name == "title" && parts[0].filename is null && parts[0].data == cast(const(ubyte)[]) "hola");
    assert(parts[1].name == "file" && parts[1].filename == "a b.txt" && parts[1].contentType == "image/png");
    assert(parts[1].data == cast(const(ubyte)[]) "hi");

    // filename* wins; a bad filename* falls back to filename. Escapes in a quoted filename are unescaped.
    body = cast(const(ubyte)[]) ("--z\r\nContent-Disposition: form-data; name=n; filename=\"a\\\"b.txt\"; "
        ~ "filename*=UTF-8''na%C3%AFve.txt\r\n\r\nx\r\n--z--\r\n");
    assert(parseMultipart(body, "z", parts) is null);
    assert(parts.length == 1 && parts[0].filename == "naïve.txt");
    body = cast(const(ubyte)[]) ("--z\r\nContent-Disposition: form-data; name=n; filename=\"plain.txt\"; "
        ~ "filename*=iso-8859-1''x\r\n\r\nx\r\n--z--\r\n");
    assert(parseMultipart(body, "z", parts) is null && parts[0].filename == "plain.txt");

    // The boundary text inside a part is data unless it is a delimiter. A following token is not a delimiter.
    body = cast(const(ubyte)[]) ("--abc\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n"
        ~ "xx--abc\r\nzz\r\n--abcX\r\n--abc--\r\n");
    assert(parseMultipart(body, "abc", parts) is null);
    assert(parts.length == 1 && parts[0].data == cast(const(ubyte)[]) "xx--abc\r\nzz\r\n--abcX");

    body = cast(const(ubyte)[]) ("--z\r\nContent-Disposition: form-data; name=\"a\"\r\n"
        ~ "Content-Type: text/plain; charset=\"UTF-8\"\r\n\r\n\r\n--z--");
    assert(parseMultipart(body, "z", parts) is null);
    assert(parts[0].data.length == 0 && parts[0].contentType == "text/plain; charset=\"UTF-8\"" && parts[0].charset == "utf-8");

    assert(parseMultipart(cast(const(ubyte)[]) "--z--\r\n", "z", parts) is null && parts.length == 0);
    assert(parseMultipart(cast(const(ubyte)[]) "--z\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhi", "z", parts)
        == malformedBody);
    assert(parseMultipart(cast(const(ubyte)[]) "--z\nContent-Disposition: form-data; name=\"a\"\n\nhi\n--z--\n", "z", parts)
        == malformedBody);
    body = cast(const(ubyte)[]) ("--z\r\nContent-Disposition: form-data; name=\"a\"\r\n"
        ~ "Content-Transfer-Encoding: base64\r\n\r\nx\r\n--z--\r\n");
    assert(parseMultipart(body, "z", parts) == malformedBody);
    body = cast(const(ubyte)[]) ("--z\r\nContent-Disposition: form-data; name=\"a\"\r\n"
        ~ "Content-Disposition: form-data; name=\"b\"\r\n\r\nx\r\n--z--\r\n");
    assert(parseMultipart(body, "z", parts) == malformedBody);

    string many;
    foreach (i; 0 .. maxMultipartParts + 1)
        many ~= "--z\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n";
    many ~= "--z--\r\n";
    assert(parseMultipart(cast(const(ubyte)[]) many, "z", parts) == tooManyParts);
    many = null;
    foreach (i; 0 .. maxMultipartParts)
        many ~= "--z\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n";
    many ~= "--z--\r\n";
    assert(parseMultipart(cast(const(ubyte)[]) many, "z", parts) is null && parts.length == maxMultipartParts);

    string huge = "--z\r\nContent-Disposition: form-data; name=\"";
    foreach (_; 0 .. maxMultipartHeaderBytes)
        huge ~= "a";
    huge ~= "\"\r\n\r\nx\r\n--z--\r\n";
    assert(parseMultipart(cast(const(ubyte)[]) huge, "z", parts) == malformedBody);
}

version (unittest)
{
    /// Decodes `body` with `MultipartScanner`, receiving it `step` bytes at a time into a window of `windowBytes`.
    private string scanInSteps(const(ubyte)[] body, string boundary, size_t step, out MultipartPart[] parts,
        size_t windowBytes = maxMultipartHeaderBytes + 64)
    {
        auto s = MultipartScanner(boundary);
        ubyte[] window = new ubyte[windowBytes];
        size_t have, fed;
        for (;;)
        {
            immutable eof = fed == body.length;
            size_t used;
            MultipartPart head;
            const(ubyte)[] data;
            immutable ev = s.next(window[0 .. have], eof, used, head, data);
            if (ev == MultipartEvent.part)
                parts ~= head;
            else if (ev == MultipartEvent.data)
                parts[$ - 1].data ~= data;
            else if (ev == MultipartEvent.done)
                return null;
            else if (ev == MultipartEvent.error)
                return s.error;
            window[0 .. have - used] = window[used .. have].dup;
            have -= used;
            if (ev == MultipartEvent.needMore && used == 0)
            {
                assert(!eof, "the scanner asked for more after the end");
                assert(have < window.length, "the scanner filled the window without deciding");
                immutable n = step < body.length - fed ? step : body.length - fed;
                immutable room = window.length - have;
                immutable take = n < room ? n : room;
                window[have .. have + take] = body[fed .. fed + take];
                have += take;
                fed += take;
            }
        }
    }
}

unittest // the scanner agrees with parseMultipart, whatever pieces the body arrives in
{
    static immutable string[2][] cases = [
        ["z", "preamble\r\n--z\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhola\r\n--z\r\n"
            ~ "Content-Disposition: form-data; name=\"file\"; filename=\"a b.txt\"\r\nContent-Type: image/png\r\n"
            ~ "Content-Transfer-Encoding: binary\r\n\r\nhi\r\n--z--\r\nepilogue"],
        ["abc", "--abc\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nxx--abc\r\nzz\r\n--abcX\r\n--abc--\r\n"],
        ["abc", "--abc  \r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n\r\r\n\r\n--ab\r\n--abc\t--  \r\n"],
        ["z", "--z\r\nContent-Disposition: form-data; name=\"a\"\r\nContent-Type: text/plain; charset=\"UTF-8\"\r\n\r\n"
            ~ "\r\n--z--"],
        ["z", "--z--\r\n"],
        ["z", "--z--"],
        ["z", "--z-- x"],
        ["z", "--z-"],
        ["z", "--z\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhi"],
        ["z", "--z\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhi\r"],
        ["z", "--z\nContent-Disposition: form-data; name=\"a\"\n\nhi\n--z--\n"],
        ["z", "--z\r\nContent-Disposition: form-data; name=\"a\"\r\nContent-Transfer-Encoding: base64\r\n\r\nx\r\n--z--\r\n"],
        ["z", "--z\r\n\r\nx\r\n--z--\r\n"],
        ["z", "--z\r\n Content-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n--z--\r\n"],
        ["z", "x--z\r\n--z\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n\r\n--z\r\n"
            ~ "Content-Disposition: form-data; name=\"b\"\r\n\r\n--z\r\n--z--\r\n"],
        ["z", "no boundary at all"],
        ["z", ""],
        ["q", "--z\r\n"],
        ["a b", "--a b\r\n"],
    ];
    string many, huge = "--z\r\nContent-Disposition: form-data; name=\"";
    foreach (i; 0 .. maxMultipartParts + 1)
        many ~= "--z\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n";
    foreach (_; 0 .. maxMultipartHeaderBytes)
        huge ~= "a";
    huge ~= "\"\r\n\r\nx\r\n--z--\r\n";
    string[2][] all = cases.dup;
    all ~= [cast(string) "z", many ~ "--z--\r\n"];
    all ~= [cast(string) "z", huge];

    foreach (ref c; all)
    {
        auto body = cast(const(ubyte)[]) c[1];
        MultipartPart[] expected;
        immutable expectedError = parseMultipart(body, c[0], expected);
        foreach (step; [1, 2, 3, 5, 7, 64, 100_000])
        {
            MultipartPart[] got;
            immutable error = scanInSteps(body, c[0], step, got);
            assert(error == expectedError, c[1]);
            if (error !is null)
                continue;
            assert(got.length == expected.length, c[1]);
            foreach (k, ref part; got)
            {
                assert(part.name == expected[k].name && part.filename == expected[k].filename, c[1]);
                assert(part.contentType == expected[k].contentType && part.charset == expected[k].charset, c[1]);
                assert(part.data == expected[k].data, c[1]);
            }
        }
    }

    // A small window decodes a large part: the content comes out as it arrives.
    string big = "--z\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x\"\r\n\r\n";
    foreach (i; 0 .. 100_000)
        big ~= cast(char) ('a' + i % 26);
    big ~= "\r\n--z--\r\n";
    MultipartPart[] parts;
    assert(scanInSteps(cast(const(ubyte)[]) big, "z", 4096, parts) is null);
    assert(parts.length == 1 && parts[0].data.length == 100_000 && parts[0].data[$ - 1] == 'a' + 99_999 % 26);
}
