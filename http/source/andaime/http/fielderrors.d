/// Validation errors in the FastAPI/Pydantic v2 shape, and the path of the field being read: shared by the JSON reader,
/// `JsonValue` and the request binders. No allocation until an error is reported.
module andaime.http.fielderrors 2025;

@safe:

import andaime.http.utf8 : codePoints;
import andaime.http.numtext : ctNum, numText;

/// Where the input of a failed field came from. Unlike `FieldError.location`, it tells a `Form!T` body (`form`) from a
/// JSON one (`jsonBody`); the default 422 says "body" for both.
enum ErrorSource
{
    path,
    query,
    header,
    cookie,
    jsonBody,
    form,
}

/// One step of a field's path: an object key or an array index.
struct LocPart
{
    string key;     /// the key (empty for an index)
    size_t index;   /// the index, when `isIndex`
    bool isIndex;
}

/// The numbers and names a rule's message is made of, so that an application can write the message in its own language
/// (`App.validationMessages`) without taking the English text apart. Only the members of the rule's `type` are set; the
/// rest are zero, and `limit`/`count` and `bound`/`min` share their storage (read the ones the table names for the `type`).
/// Stored inline in the error: reporting one allocates nothing beyond what it always did, and it is kept to 40 bytes
/// because a `Context` holds sixteen errors and must stay under the GC's 4096-byte page class (1,000 requests in flight
/// cost 4 MB more when it did not).
///
/// | `type` | set |
/// |--------|-----|
/// | `string_too_short`, `string_too_long` | `limit`: characters |
/// | `too_short`, `too_long` | `limit`: items |
/// | `bytes_too_short`, `bytes_too_long` | `limit`: bytes |
/// | `greater_than_equal`, `less_than_equal` | `bound`: the minimum, or the maximum, of `@inRange` |
/// | `int_parsing` | `min`, `max`: the range of the integer type |
/// | `enum` | `allowed`: the wire names |
/// | `too_many_errors` | `count`: errors not shown |
struct FieldParams
{
    union
    {
        ulong limit;
        size_t count;
    }
    union
    {
        double bound;
        long min;
    }
    ulong max;
    const(string)[] allowed;

    /// A length or count rule: `limit` characters, items or bytes.
    static FieldParams ofLimit(ulong n) pure nothrow @nogc @safe
    {
        FieldParams p;
        p.limit = n;
        return p;
    }

    /// An `@inRange` bound.
    static FieldParams ofBound(double v) pure nothrow @nogc @safe
    {
        FieldParams p;
        p.bound = v;
        return p;
    }

    /// The range of an integer type.
    static FieldParams ofRange(long min, ulong max) pure nothrow @nogc @safe
    {
        FieldParams p;
        p.min = min;
        p.max = max;
        return p;
    }

    /// The wire names of an enum.
    static FieldParams ofAllowed(return scope const(string)[] names) pure nothrow @nogc @safe
    {
        FieldParams p;
        p.allowed = names;
        return p;
    }

    /// Errors not shown.
    static FieldParams ofCount(size_t n) pure nothrow @nogc @safe
    {
        FieldParams p;
        p.count = n;
        return p;
    }
}

static assert(FieldParams.sizeof == 40);

/// A validation error, in FastAPI/Pydantic v2 shape: `{"type":..., "loc":[location, ...], "msg":...}`.
struct FieldError
{
    string location;  /// "path", "query", "header", "cookie" or "body": the first element of `loc`
    string locJson;   /// the rest of `loc`, already rendered as JSON array elements: `"items",1,"code"` ("" = none)
    string type;      /// machine-readable code ("missing", "int_parsing", "string_too_short"...)
    string message;
    ErrorSource source; /// where the input came from (see `ErrorSource`)
    FieldParams params; /// what the rule's message was made of (see `FieldParams`)

    /// The rest of `loc` as keys and indexes: `items`, `1`, `code`. Allocates; meant for error handlers. A path cut at
    /// `FieldPath.maxDepth` ends with the key `...`.
    LocPart[] path() const pure nothrow @safe
    {
        LocPart[] r;
        auto s = locJson;
        size_t i = 0;
        while (i < s.length)
        {
            if (s[i] == '"')
            {
                char[] key;
                i++;
                while (i < s.length && s[i] != '"')
                {
                    if (s[i] == '\\' && i + 1 < s.length)
                    {
                        i++;
                        if (s[i] == 'u' && i + 4 < s.length) // \u00XX, the only other escape jsonQuote writes
                        {
                            key ~= cast(char)(hexVal(s[i + 3]) << 4 | hexVal(s[i + 4]));
                            i += 5;
                            continue;
                        }
                    }
                    key ~= s[i++];
                }
                i++; // closing quote
                r ~= LocPart((() @trusted => cast(string) key)(), 0, false); // sole owner: safe to make immutable
            }
            else
            {
                size_t n = 0;
                while (i < s.length && s[i] >= '0' && s[i] <= '9')
                    n = n * 10 + (s[i++] - '0');
                r ~= LocPart(null, n, true);
            }
            if (i < s.length && s[i] == ',')
                i++;
        }
        return r;
    }

    /// The path as one string, keys and indexes joined by dots: `items.1.code` ("" when `loc` is just the location).
    string dotted() const pure nothrow @safe
    {
        string r;
        foreach (k, p; path())
        {
            if (k)
                r ~= '.';
            r ~= p.isIndex ? ctNum(p.index) : p.key;
        }
        return r;
    }
}

private uint hexVal(char c) pure nothrow @nogc @safe
    => c >= '0' && c <= '9' ? c - '0' : (c >= 'a' && c <= 'f' ? c - 'a' + 10 : 0);

/// The source of an error added with a location name (path, query, header, cookie; anything else is a JSON body).
ErrorSource sourceOf(string location) pure nothrow @nogc @safe
{
    switch (location)
    {
        case "path": return ErrorSource.path;
        case "query": return ErrorSource.query;
        case "header": return ErrorSource.header;
        case "cookie": return ErrorSource.cookie;
        default: return ErrorSource.jsonBody;
    }
}

/// What a validation error handler (`App.onValidationError`) receives: the errors of the request, in the order they
/// were found, and how many more were dropped past `FieldErrors.capacity`. A view into the request's context: valid
/// during the handler only.
struct ValidationErrors
{
    const(FieldError)[] items;
    size_t dropped;

    /// True when some error came from `source`: `if (errors.has(ErrorSource.path)) ... 404`.
    bool has(ErrorSource source) const pure nothrow @nogc @safe scope
    {
        foreach (ref e; items)
            if (e.source == source)
                return true;
        return false;
    }
}

/// Fixed capacity: collecting errors never allocates up front (only an actual error renders its location).
/// Extras are counted and reported as one `too_many_errors` entry.
struct FieldErrors
{
    enum size_t capacity = 16;
    FieldError[capacity] items;
    size_t count;
    size_t dropped;

    /// Error on a single named input (query parameter, header, path segment). An empty `name` means `loc` is just
    /// `[location]`.
    void add(string location, scope const(char)[] name, string type, string message, FieldParams params = FieldParams.init)
        nothrow @safe
    {
        if (count >= capacity)
        {
            dropped++;
            return;
        }
        items[count++] = FieldError(location, name.length ? jsonQuote(name) : null, type, message, sourceOf(location), params);
    }

    /// Error on one element of a list given as repeated query parameters: `loc` is `["query", name, index]`.
    void addIndexed(string location, scope const(char)[] name, size_t index, string type, string message,
        FieldParams params = FieldParams.init) nothrow @safe
    {
        if (count >= capacity)
        {
            dropped++;
            return;
        }
        items[count++] = FieldError(location, jsonQuote(name) ~ "," ~ ctNum(index), type, message, sourceOf(location), params);
    }

    /// Error somewhere in a JSON body.
    void addPath(ref const FieldPath path, string type, string message, FieldParams params = FieldParams.init) nothrow @safe
    {
        if (count >= capacity)
        {
            dropped++;
            return;
        }
        items[count++] = FieldError(path.location, path.render(), type, message, path.source, params);
    }

    /// The errors as a handler sees them (`App.onValidationError`).
    ValidationErrors view() const nothrow @nogc @safe return => ValidationErrors(items[0 .. count], dropped);

    bool any() const nothrow @nogc @safe => count > 0;

    void clear() nothrow @nogc @safe
    {
        count = 0;
        dropped = 0;
    }

    const(FieldError)[] list() const nothrow @nogc @safe return => items[0 .. count];
}

/// `"text"` as JSON (only `"`, `\` and control characters need escaping here: keys and parameter names).
string jsonQuote(scope const(char)[] s) pure nothrow @safe
{
    static immutable char[16] hexd = "0123456789abcdef";
    char[] o = new char[s.length + 2];
    o.length = 0;
    o ~= '"';
    foreach (char c; s)
    {
        if (c == '"' || c == '\\')
        {
            o ~= '\\';
            o ~= c;
        }
        else if (c < 0x20)
        {
            o ~= "\\u00";
            o ~= hexd[c >> 4];
            o ~= hexd[c & 15];
        }
        else
            o ~= c;
    }
    o ~= '"';
    return (() @trusted => cast(string) o)(); // sole owner: safe to make immutable
}

/// Path of the current field (`items`, `[1]`, `code`) in a fixed stack: it only becomes a string (allocating) when an
/// error needs to be reported. Deeper than `maxDepth` segments, the extra ones are counted but not stored and
/// `render` ends with `"..."`.
struct FieldPath
{
    enum size_t maxDepth = 32;

    private struct Seg
    {
        const(char)[] key;
        size_t index;
        bool isIndex;
    }

    private Seg[maxDepth] segs;
    private size_t depth;
    /// First element of `loc` for errors reported with this path: "body" (JSON), or "query" / "body" for `Query!T`/`Form!T`.
    string location = "body";
    /// Where the input came from: `jsonBody`, or `query` / `form` for `Query!T`/`Form!T`.
    ErrorSource source = ErrorSource.jsonBody;

    /// Enters an object member. Returns the mark to give back to `pop`. `key` must outlive the parse (a literal).
    size_t pushKey(const(char)[] key) nothrow @nogc @safe
    {
        immutable mark = depth;
        if (depth < maxDepth)
            segs[depth] = Seg(key, 0, false);
        depth++;
        return mark;
    }

    /// Enters an array element.
    size_t pushIndex(size_t i) nothrow @nogc @safe
    {
        immutable mark = depth;
        if (depth < maxDepth)
            segs[depth] = Seg(null, i, true);
        depth++;
        return mark;
    }

    void pop(size_t mark) nothrow @nogc @safe
    {
        depth = mark;
    }

    bool empty() const nothrow @nogc @safe => depth == 0;

    /// `"items",1,"code"` ("" for the root).
    string render() const nothrow @safe scope
    {
        string r;
        immutable n = depth < maxDepth ? depth : maxDepth;
        foreach (k; 0 .. n)
        {
            if (k)
                r ~= ",";
            r ~= segs[k].isIndex ? ctNum(segs[k].index) : jsonQuote(segs[k].key);
        }
        if (depth > maxDepth)
            r ~= `,"..."`;
        return r;
    }
}
