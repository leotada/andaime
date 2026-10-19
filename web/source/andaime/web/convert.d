/// Text -> scalar conversions without std.conv (compiles fast, does not allocate).
module andaime.web.convert 2025;

import andaime.web.params : isCharType;
import andaime.web.numtext : ctNum, itoa;
import andaime.http.texttype : isTextType, textTypeInvalidMessage, textFromString;
import andaime.http.naming : enumWireNames, parseEnumWire;
public import andaime.http.numparse : parseInteger, parseFloat;

@safe:

bool parseBool(scope const(char)[] s, out bool v) pure nothrow @nogc
{
    switch (s)
    {
        case "true", "1": v = true; return true;
        case "false", "0": v = false; return true;
        default: return false;
    }
}

/// Decodes %XX (and '+' as space, in the query). With nothing to decode,
/// returns the slice itself: zero-copy in the common case.
bool percentDecode(const(char)[] raw, bool plusIsSpace, out const(char)[] result) pure nothrow
{
    bool needs = false;
    foreach (char c; raw)
        if (c == '%' || (plusIsSpace && c == '+'))
        {
            needs = true;
            break;
        }
    if (!needs)
    {
        result = raw;
        return true;
    }
    static int hex(char c) pure nothrow @nogc
    {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    auto o = new char[raw.length];
    size_t n = 0;
    for (size_t i = 0; i < raw.length; i++)
    {
        char c = raw[i];
        if (c == '%')
        {
            if (i + 2 >= raw.length)
                return false;
            int h = hex(raw[i + 1]), l = hex(raw[i + 2]);
            if (h < 0 || l < 0)
                return false;
            o[n++] = cast(char)(h * 16 + l);
            i += 2;
        }
        else
            o[n++] = (plusIsSpace && c == '+') ? ' ' : c;
    }
    result = o[0 .. n];
    return true;
}

/// Already-decoded text -> T. `string` is copied (the network buffer will be
/// reused); `const(char)[]` is returned as a slice (zero-copy).
bool parseScalarText(T)(const(char)[] s, out T v)
{
    static if (is(T == bool))
        return parseBool(s, v);
    else static if (is(T == enum))
        return parseEnumWire(s, v);
    else static if (__traits(isIntegral, T) && !isCharType!T)
        return parseInteger(s, v);
    else static if (__traits(isFloating, T))
        return parseFloat(s, v);
    else static if (is(T == string))
    {
        v = s.idup;
        return true;
    }
    else static if (is(T == const(char)[]))
    {
        v = s;
        return true;
    }
    else static if (isTextType!T)
        return textFromString(s, v);
    else
        static assert(0, "andaime: '" ~ T.stringof ~ "' is not a supported scalar");
}

/// Machine-readable `type` of a failed conversion to T (Pydantic v2 names), built at compile time.
template parseErrorType(T)
{
    static if (is(T == bool))
        enum parseErrorType = "bool_parsing";
    else static if (is(T == enum))
        enum parseErrorType = "enum";
    else static if (__traits(isIntegral, T))
        enum parseErrorType = "int_parsing";
    else static if (__traits(isFloating, T))
        enum parseErrorType = "float_parsing";
    else
        enum parseErrorType = "value_error"; // also a text type's fromString refusing the text
}

/// Human message for a failed conversion to T, built at compile time.
template parseErrorMsg(T)
{
    static if (is(T == bool))
        enum parseErrorMsg = "expected true or false";
    else static if (is(T == enum))
    {
        enum parseErrorMsg = () {
            string r = "expected one of: ";
            foreach (k, w; enumWireNames!T)
                r ~= (k ? ", " : "") ~ w;
            return r;
        }();
    }
    else static if (__traits(isIntegral, T))
    {
        static if (__traits(isUnsigned, T))
            enum parseErrorMsg = "expected an integer between 0 and " ~ ctNum(T.max);
        else
            enum parseErrorMsg = "expected an integer between " ~ itoa(T.min) ~ " and " ~ itoa(T.max);
    }
    else static if (__traits(isFloating, T))
        enum parseErrorMsg = "expected a number";
    else static if (isTextType!T)
        enum parseErrorMsg = textTypeInvalidMessage!T;
    else
        enum parseErrorMsg = "invalid value";
}

unittest
{
    int i;
    assert(parseInteger("-2147483648", i) && i == int.min);
    assert(!parseInteger("2147483648", i));
    ubyte b;
    assert(parseInteger("255", b) && b == 255);
    assert(!parseInteger("256", b) && !parseInteger("-1", b));
    long l;
    assert(parseInteger("-9223372036854775808", l) && l == long.min);
    double d;
    assert(parseFloat("1.5e3", d) && d == 1500);
    assert(!parseFloat("inf", d) && !parseFloat("1.5x", d));
    const(char)[] r;
    assert(percentDecode("ana+maria%20s", true, r) && r == "ana maria s");
    string plain = "abc";
    assert(percentDecode(plain, true, r) && r.ptr == plain.ptr); // zero-copy
    assert(!percentDecode("%4", true, r) && !percentDecode("%zz", true, r));
    enum Color { red, green }
    Color c;
    assert(parseScalarText("green", c) && c == Color.green);
}
