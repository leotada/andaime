/// Text types: your own value types (a UUID, a date, an amount) that travel as text in a path, a query string, a header, a
/// JSON string and a database column. A type opts in by following D's usual `toString` convention:
///
///     struct Uuid
///     {
///         ubyte[16] bytes;
///         static bool fromString(scope const(char)[] text, out Uuid v);                 // false = not a valid value
///         void toString(scope void delegate(scope const(char)[]) @safe sink) const;     // writes the text
///         enum openApiFormat = "uuid";                                                   // optional
///         enum invalidMessage = "expected a UUID like 123e4567-e89b-12d3-a456-426614174000"; // optional
///     }
///
/// Nothing is registered anywhere: the compiler checks the shape. The core never needs `std.datetime` or any other
/// library (`andaime.values` has `Uuid`, `Timestamp` and `CalendarDate` as text types); an application type may use
/// whatever it likes inside `fromString`/`toString`.
module andaime.http.texttype 2025;

@safe:

/// True when `T` holds no pointer, slice, class reference, associative array or delegate, so it cannot keep a view of
/// the text it was parsed from (`Uuid`, `Timestamp` and `CalendarDate` are such types). A type with indirections may
/// store the slice it is given, which is why the framework hands it a copy (see `parseScalarText`).
template hasIndirections(T)
{
    static if (is(T == struct) || is(T == union))
    {
        enum bool hasIndirections = () {
            bool r = false;
            static foreach (F; typeof(T.tupleof))
                r |= hasIndirections!F;
            return r;
        }();
    }
    else static if (is(T == U[N], U, size_t N))
        enum bool hasIndirections = hasIndirections!U;
    else
        enum bool hasIndirections = is(T == class) || is(T == interface)
            || is(T == U*, U) || is(T == U[], U) || is(T == V[K], V, K)
            || is(T == delegate);
}

/// Whether the first parameter of `fn` is `scope` (or `in`, which implies it).
private template hasScopedFirstParam(alias fn)
{
    static if (is(typeof(fn) P == __parameters) && P.length >= 1)
    {
        enum bool hasScopedFirstParam = () {
            foreach (s; __traits(getParameterStorageClasses, fn, 0))
                if (s == "scope" || s == "in")
                    return true;
            return false;
        }();
    }
    else
        enum bool hasScopedFirstParam = false;
}

/// Whether some `T.fromString` takes its text as `scope` (a struct without `fromString` has none). Guarded here, not in
/// the caller: D analyses both sides of an `&&`, so `T.fromString` must not be named for a `T` that lacks it.
private template scopedFromString(T)
{
    enum bool scopedFromString = () {
        static if (is(T == struct) && __traits(hasMember, T, "fromString"))
        {
            static foreach (o; __traits(getOverloads, T, "fromString"))
                static if (hasScopedFirstParam!o)
                    return true;
        }
        return false;
    }();
}

/// True if `T` follows the text-type protocol above. `fromString` must take its text as `scope`: the framework parses
/// from a buffer that the next request reuses, and `scope` is the promise that the callee does not keep it.
enum isTextType(T) = is(T == struct)
    && __traits(compiles, () @trusted { T v; scope const(char)[] s; bool ok = T.fromString(s, v); })
    && scopedFromString!T
    && __traits(compiles, () @trusted { const T c; c.toString((scope const(char)[] piece) {}); });

/// True when `T` has `fromString` and `toString` but `fromString` does not take its text as `scope`, so `isTextType` is
/// false. Used to say so in one line where a text type was meant (`handlerError`, `modelError`, the JSON codec).
enum hasUnscopedFromString(T) = is(T == struct) && !isTextType!T
    && __traits(compiles, () @trusted { T v; const(char)[] s; bool ok = T.fromString(s, v); })
    && __traits(compiles, () @trusted { const T c; c.toString((scope const(char)[] piece) {}); });

/// The two places where a text type's own code is called from `@safe` framework code (like every user callback, it
/// may be `@system`). A `@safe` `fromString` is called as `@safe` code, so that under DIP1000 the compiler checks that
/// it does not keep `text`; only a `@system` one goes through `@trusted` (the callee's safety is its author's business;
/// nothing here touches its memory).
bool textFromString(T)(scope const(char)[] text, out T v) @safe
    if (isTextType!T)
{
    static if (__traits(compiles, () @safe { T tmp; scope const(char)[] s; return T.fromString(s, tmp); }))
        return T.fromString(text, v);
    else
        return (() @trusted => T.fromString(text, v))(); // sound: a @system callback is its author's responsibility
}

/// ditto
void textToString(T)(const T v, scope void delegate(scope const(char)[]) @safe sink) @trusted
    if (isTextType!T)
{
    v.toString(sink);
}

/// The OpenAPI `format` of a text type ("" when it declares none).
template textTypeFormat(T)
{
    static if (__traits(hasMember, T, "openApiFormat"))
        enum string textTypeFormat = T.openApiFormat;
    else
        enum string textTypeFormat = "";
}

/// The message for a value that `fromString` refused.
template textTypeInvalidMessage(T)
{
    static if (__traits(hasMember, T, "invalidMessage"))
        enum string textTypeInvalidMessage = T.invalidMessage;
    else
        enum string textTypeInvalidMessage = "invalid " ~ T.stringof;
}

version (unittest)
{
    private struct Digits
    {
        int v;

        static bool fromString(scope const(char)[] text, out Digits d)
        {
            if (text.length == 0)
                return false;
            int acc;
            foreach (c; text)
            {
                if (c < '0' || c > '9')
                    return false;
                acc = acc * 10 + (c - '0');
            }
            d.v = acc;
            return true;
        }

        void toString(scope void delegate(scope const(char)[]) @safe sink) const
        {
            char[12] t;
            size_t n = t.length;
            int x = v;
            do { t[--n] = cast(char)('0' + x % 10); x /= 10; } while (x);
            sink(t[n .. $]);
        }

        enum openApiFormat = "digits";
    }

    private struct NotText { int v; }                  // no fromString
    private struct HalfText { static bool fromString(scope const(char)[] t, out HalfText v) => true; } // no toString

    // fromString without `scope`: it may keep the slice, so it is not a text type
    private struct Unscoped
    {
        const(char)[] raw;

        static bool fromString(const(char)[] t, out Unscoped v)
        {
            v.raw = t;
            return true;
        }

        void toString(scope void delegate(scope const(char)[]) @safe sink) const { sink(raw); }
    }

    // keeps a copy: a type with indirections that is still a text type
    private struct Copying
    {
        string text;

        static bool fromString(scope const(char)[] t, out Copying v)
        {
            v.text = t.idup;
            return true;
        }

        void toString(scope void delegate(scope const(char)[]) @safe sink) const { sink(text); }
    }
}

unittest
{
    static assert(isTextType!Digits && !isTextType!NotText && !isTextType!HalfText && !isTextType!int && !isTextType!string);
    static assert(textTypeFormat!Digits == "digits" && textTypeFormat!NotText == "");
    static assert(textTypeInvalidMessage!Digits == "invalid Digits");

    // `scope` on the first parameter of fromString is part of the protocol
    static assert(!isTextType!Unscoped && hasUnscopedFromString!Unscoped);
    static assert(!hasUnscopedFromString!Digits && !hasUnscopedFromString!NotText && !hasUnscopedFromString!HalfText);
    static assert(isTextType!Copying && !hasUnscopedFromString!Copying);

    // which types can keep a view of their input
    static assert(!hasIndirections!Digits && !hasIndirections!int && !hasIndirections!(ubyte[16]));
    static assert(hasIndirections!Unscoped && hasIndirections!Copying && hasIndirections!(int[]) && hasIndirections!(int*));
    static assert(hasIndirections!(int[string]));

    // a copying fromString is called as @safe code
    Copying c;
    assert(textFromString("abc", c) && c.text == "abc");
    Digits d;
    assert(textFromString("42", d) && d.v == 42);
}
