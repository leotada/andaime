/// DTO UDAs and the validation error accumulator (FastAPI format).
module vela.web.dto;

@safe:

/// Field name in the JSON when it differs from the D name: `@jsonKey("user_name") string userName;`
struct jsonKey { string name; }
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

/// A validation error. `location` is "path", "query", "header" or "body".
struct FieldError
{
    string location;
    const(char)[] field;
    string message;
}

/// Fixed capacity: collecting errors never allocates. Extras are only counted.
struct FieldErrors
{
    enum size_t capacity = 16;
    FieldError[capacity] items;
    size_t count;
    size_t dropped;

    void add(string location, const(char)[] field, string message) nothrow @nogc @safe
    {
        if (count < capacity)
            items[count++] = FieldError(location, field, message);
        else
            dropped++;
    }

    bool any() const nothrow @nogc @safe => count > 0;

    void clear() nothrow @nogc @safe
    {
        count = 0;
        dropped = 0;
    }

    const(FieldError)[] list() const nothrow @nogc @safe return => items[0 .. count];
}

/// Path of the current field ("address.zip") in a fixed buffer: only becomes a
/// string (allocating) when an error needs to be reported.
struct FieldPath
{
    private char[192] buf;
    private size_t len;

    size_t push(scope const(char)[] key) nothrow @nogc @safe
    {
        immutable old = len;
        if (len && len < buf.length)
            buf[len++] = '.';
        immutable n = key.length < buf.length - len ? key.length : buf.length - len;
        buf[len .. len + n] = key[0 .. n];
        len += n;
        return old;
    }

    void pop(size_t mark) nothrow @nogc @safe
    {
        len = mark;
    }

    const(char)[] current() const nothrow @nogc @safe return => buf[0 .. len];
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

/// Number -> text at CTFE (avoids std.conv in the core).
string ctNum(ulong v) pure nothrow @safe
{
    if (v == 0)
        return "0";
    string r;
    while (v)
    {
        r = cast(char)('0' + v % 10) ~ r;
        v /= 10;
    }
    return r;
}

private enum string minLenMsg(size_t n) = "below the minimum length of " ~ ctNum(n);
private enum string maxLenMsg(size_t n) = "above the maximum length of " ~ ctNum(n);

/// Applies the validation UDAs of field `i` to the already-decoded value.
void validateField(T, size_t i, V)(ref const V value, ref FieldErrors errs, ref const FieldPath path)
{
    static foreach (attr; __traits(getAttributes, T.tupleof[i]))
    {
        static if (is(typeof(attr) == minLength))
        {
            static assert(__traits(compiles, value.length),
                "vela: @minLength only applies to string or array (field '" ~ __traits(identifier, T.tupleof[i]) ~ "')");
            if (value.length < attr.value)
                errs.add("body", path.current.idup, minLenMsg!(attr.value));
        }
        else static if (is(typeof(attr) == maxLength))
        {
            static assert(__traits(compiles, value.length),
                "vela: @maxLength only applies to string or array (field '" ~ __traits(identifier, T.tupleof[i]) ~ "')");
            if (value.length > attr.value)
                errs.add("body", path.current.idup, maxLenMsg!(attr.value));
        }
        else static if (is(typeof(attr) == inRange))
        {
            static assert(__traits(isArithmetic, V),
                "vela: @inRange only applies to numbers (field '" ~ __traits(identifier, T.tupleof[i]) ~ "')");
            if (value < attr.min || value > attr.max)
                errs.add("body", path.current.idup, "outside the allowed range");
        }
    }
}
