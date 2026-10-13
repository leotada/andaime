/// DTO UDAs and the validation error accumulator (FastAPI format).
module vela.web.dto;

@safe:

import vela.http.utf8 : codePoints;
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

/// A validation error, in FastAPI/Pydantic v2 shape: `{"type":..., "loc":[location, ...], "msg":...}`.
struct FieldError
{
    string location;  /// "path", "query", "header" or "body": the first element of `loc`
    string locJson;   /// the rest of `loc`, already rendered as JSON array elements: `"items",1,"code"` ("" = none)
    string type;      /// machine-readable code ("missing", "int_parsing", "string_too_short"...)
    string message;
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
        items[count++] = FieldError(location, name.length ? jsonQuote(name) : null, type, message);
    }

    /// Error on one element of a list given as repeated query parameters: `loc` is `["query", name, index]`.
    void addIndexed(string location, scope const(char)[] name, size_t index, string type, string message) nothrow @safe
    {
        if (count >= capacity)
        {
            dropped++;
            return;
        }
        items[count++] = FieldError(location, jsonQuote(name) ~ "," ~ ctNum(index), type, message);
    }

    /// Error somewhere in a JSON body.
    void addPath(scope ref const FieldPath path, string type, string message) nothrow @safe
    {
        if (count >= capacity)
        {
            dropped++;
            return;
        }
        items[count++] = FieldError(path.location, path.render(), type, message);
    }

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
    string render() const nothrow @safe
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

/// JSON key of field `i` of T.
template jsonKeyOf(T, size_t i)
{
    enum jsonKeyOf = () {
        string r = __traits(identifier, T.tupleof[i]);
        static foreach (attr; __traits(getAttributes, T.tupleof[i]))
            static if (is(typeof(attr) == jsonKey))
                r = attr.name;
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
    static foreach (attr; __traits(getAttributes, T.tupleof[i]))
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
