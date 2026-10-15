/// DTO UDAs and the validation error accumulator (FastAPI format).
module vela.web.dto;

@safe:

import vela.http.utf8 : codePoints;
import vela.http.patchfield : isPatchField;
import vela.http.naming : applyNaming, namingOf, naming, Naming;
public import vela.web.numtext : ctNum, numText;

/// Field name in the JSON when it differs from the D name: `@jsonKey("user_name") string userName;`
struct jsonKey { string name; }
/// Name of the struct's schema in the OpenAPI document: `@schemaName("UserOut") struct User { ... }`.
struct schemaName { string name; }
/// Optional field in the JSON (absent => keeps the initial value).
enum optional;
/// Field never read from or written to JSON.
enum jsonIgnore;
/// Minimum string/array length.
struct minLength { size_t value; }
/// Maximum string/array length.
struct maxLength { size_t value; }
/// Closed range for numbers: `@inRange(0, 150) int age;`
struct inRange { double min; double max; }

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

/// A validation error, in FastAPI/Pydantic v2 shape: `{"type":..., "loc":[location, ...], "msg":...}`.
struct FieldError
{
    string location;  /// "path", "query", "header", "cookie" or "body": the first element of `loc`
    string locJson;   /// the rest of `loc`, already rendered as JSON array elements: `"items",1,"code"` ("" = none)
    string type;      /// machine-readable code ("missing", "int_parsing", "string_too_short"...)
    string message;
    ErrorSource source; /// where the input came from (see `ErrorSource`)

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
    void add(string location, scope const(char)[] name, string type, string message) nothrow @safe
    {
        if (count >= capacity)
        {
            dropped++;
            return;
        }
        items[count++] = FieldError(location, name.length ? jsonQuote(name) : null, type, message, sourceOf(location));
    }

    /// Error on one element of a list given as repeated query parameters: `loc` is `["query", name, index]`.
    void addIndexed(string location, scope const(char)[] name, size_t index, string type, string message) nothrow @safe
    {
        if (count >= capacity)
        {
            dropped++;
            return;
        }
        items[count++] = FieldError(location, jsonQuote(name) ~ "," ~ ctNum(index), type, message, sourceOf(location));
    }

    /// Error somewhere in a JSON body.
    void addPath(ref const FieldPath path, string type, string message) nothrow @safe
    {
        if (count >= capacity)
        {
            dropped++;
            return;
        }
        items[count++] = FieldError(path.location, path.render(), type, message, path.source);
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

/// true if member `i` of T carries the UDA `A` (type or enum).
template hasUda(T, size_t i, alias A)
{
    enum hasUda = () {
        bool r;
        static foreach (attr; __traits(getAttributes, T.tupleof[i]))
            static if (is(attr == A) || is(typeof(attr) == A))
                r = true;
        return r;
    }();
}

/// JSON key of field `i` of T: its `@jsonKey`, else its name spelled with T's `@naming` (`vela.http.naming`). Also
/// the name of the field in `Query!T`, `Form!T` and the OpenAPI document.
template jsonKeyOf(T, size_t i)
{
    // (the common case, no attribute and no policy, costs no CTFE: this runs for every field of every DTO)
    static if (__traits(getAttributes, T.tupleof[i]).length == 0)
    {
        static if (namingOf!T == Naming.asIs)
            enum jsonKeyOf = __traits(identifier, T.tupleof[i]);
        else
            enum jsonKeyOf = applyNaming(__traits(identifier, T.tupleof[i]), namingOf!T);
    }
    else
    {
        enum jsonKeyOf = () {
            string r = applyNaming(__traits(identifier, T.tupleof[i]), namingOf!T);
            static foreach (attr; __traits(getAttributes, T.tupleof[i]))
                static if (is(typeof(attr) == jsonKey))
                    r = attr.name;
            return r;
        }();
        static assert(!fieldHasNaming!(T, i), "vela: @naming goes on the struct, not on field '"
            ~ __traits(identifier, T.tupleof[i]) ~ "' of " ~ T.stringof ~ " (use @jsonKey for one field)");
    }
}

private template fieldHasNaming(T, size_t i)
{
    enum fieldHasNaming = () {
        bool r;
        static foreach (attr; __traits(getAttributes, T.tupleof[i]))
            static if (is(typeof(attr) == naming))
                r = true;
        return r;
    }();
}

private enum string strShort(size_t n) = "expected at least " ~ ctNum(n) ~ " characters";
private enum string strLong(size_t n) = "expected at most " ~ ctNum(n) ~ " characters";
private enum string arrShort(size_t n) = "expected at least " ~ ctNum(n) ~ " items";
private enum string arrLong(size_t n) = "expected at most " ~ ctNum(n) ~ " items";
private enum string geMsg(double v) = "must be >= " ~ numText(v);
private enum string leMsg(double v) = "must be <= " ~ numText(v);

/// Applies the validation UDAs of field `i` to the already-decoded value. Strings are measured in code points (what
/// JSON Schema's minLength/maxLength mean and what the OpenAPI document promises), arrays in elements.
void validateField(T, size_t i, V)(ref const V value, ref FieldErrors errs, ref const FieldPath path)
{
    // a PatchField is checked only when it carries a value (absent and null pass)
    static if (isPatchField!V)
    {
        if (value.hasValue)
            validateField!(T, i)(value.value, errs, path);
    }
    else static foreach (attr; __traits(getAttributes, T.tupleof[i]))
    {
        static if (is(typeof(attr) == minLength))
        {
            static assert(__traits(compiles, value.length),
                "vela: @minLength only applies to string or array (field '" ~ __traits(identifier, T.tupleof[i]) ~ "')");
            static if (is(V : const(char)[]))
            {
                if (codePoints(value) < attr.value)
                    errs.addPath(path, "string_too_short", strShort!(attr.value));
            }
            else if (value.length < attr.value)
                errs.addPath(path, "too_short", arrShort!(attr.value));
        }
        else static if (is(typeof(attr) == maxLength))
        {
            static assert(__traits(compiles, value.length),
                "vela: @maxLength only applies to string or array (field '" ~ __traits(identifier, T.tupleof[i]) ~ "')");
            static if (is(V : const(char)[]))
            {
                if (codePoints(value) > attr.value)
                    errs.addPath(path, "string_too_long", strLong!(attr.value));
            }
            else if (value.length > attr.value)
                errs.addPath(path, "too_long", arrLong!(attr.value));
        }
        else static if (is(typeof(attr) == inRange))
        {
            static assert(__traits(isArithmetic, V),
                "vela: @inRange only applies to numbers (field '" ~ __traits(identifier, T.tupleof[i]) ~ "')");
            if (value < attr.min)
                errs.addPath(path, "greater_than_equal", geMsg!(attr.min));
            else if (value > attr.max)
                errs.addPath(path, "less_than_equal", leMsg!(attr.max));
        }
    }
}

unittest
{
    @naming(Naming.snakeCase) struct S { string firstName; @jsonKey("ID") long userId; string body_; }
    static assert(jsonKeyOf!(S, 0) == "first_name" && jsonKeyOf!(S, 1) == "ID" && jsonKeyOf!(S, 2) == "body");
    struct Plain { string firstName; }
    static assert(jsonKeyOf!(Plain, 0) == "firstName");
    struct Misplaced { @naming(Naming.snakeCase) string firstName; }
    static assert(fieldHasNaming!(Misplaced, 0) && !__traits(compiles, jsonKeyOf!(Misplaced, 0)));
}

unittest
{
    FieldErrors errs;
    FieldPath p;
    p.pushKey("items");
    p.pushIndex(12);
    p.pushKey("a\"b\x01");
    errs.addPath(p, "missing", "Field required");
    errs.add("query", "limit", "missing", "Field required");
    errs.add("body", "", "json_invalid", "invalid JSON at byte 3");
    auto v = errs.view;
    assert(v.items.length == 3 && v.dropped == 0);
    assert(v.items[0].source == ErrorSource.jsonBody && v.items[1].source == ErrorSource.query);
    assert(v.items[0].path == [LocPart("items"), LocPart(null, 12, true), LocPart("a\"b\x01")]);
    assert(v.items[0].dotted == "items.12.a\"b\x01");
    assert(v.items[1].dotted == "limit" && v.items[2].path.length == 0 && v.items[2].dotted == "");
    assert(v.has(ErrorSource.query) && !v.has(ErrorSource.path));
}
