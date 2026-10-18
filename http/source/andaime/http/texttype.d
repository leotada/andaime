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
/// library; an application type may use whatever it likes inside `fromString`/`toString`.
module andaime.http.texttype;

@safe:

/// True if `T` follows the text-type protocol above.
enum isTextType(T) = is(T == struct)
    && __traits(compiles, () @trusted { T v; const(char)[] s; bool ok = T.fromString(s, v); })
    && __traits(compiles, () @trusted { const T c; c.toString((scope const(char)[] piece) {}); });

/// The two places where a text type's own code is called from `@safe` framework code (like every user callback, it
/// may be `@system`). @trusted: the callee's safety is its author's business; nothing here touches its memory.
bool textFromString(T)(scope const(char)[] text, out T v) @trusted
    if (isTextType!T)
{
    return T.fromString(text, v);
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
}

unittest
{
    static assert(isTextType!Digits && !isTextType!NotText && !isTextType!HalfText && !isTextType!int && !isTextType!string);
    static assert(textTypeFormat!Digits == "digits" && textTypeFormat!NotText == "");
    static assert(textTypeInvalidMessage!Digits == "invalid Digits");
}
