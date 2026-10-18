/// Number -> text without std.conv/std.format. Works at compile time (messages built in CTFE) and at run time.
module andaime.web.numtext 2025;

@safe:

/// Unsigned integer as text.
string ctNum(ulong v) pure nothrow
{
    if (v == 0)
        return "0";
    char[20] t;
    size_t n = t.length;
    while (v)
    {
        t[--n] = cast(char)('0' + v % 10);
        v /= 10;
    }
    return t[n .. $].idup;
}

/// Signed integer as text.
string itoa(long v) pure nothrow
{
    if (v >= 0)
        return ctNum(v);
    return "-" ~ ctNum(cast(ulong)(-(v + 1)) + 1); // no overflow for long.min
}

/// A double as short text: integers without an exponent ("150"), otherwise the shortest of up to 9 decimals at
/// compile time or `%.17g` at run time (@inRange bounds are usually integers).
string numText(double v) nothrow
{
    if (v == cast(long) v && v > -1e15 && v < 1e15)
        return itoa(cast(long) v);
    if (__ctfe)
    {
        string sign = v < 0 ? "-" : "";
        double a = v < 0 ? -v : v;
        ulong whole = cast(ulong) a;
        double frac = a - whole;
        char[9] digits;
        foreach (ref d; digits)
        {
            frac *= 10;
            immutable k = cast(int) frac;
            d = cast(char)('0' + k);
            frac -= k;
        }
        size_t n = digits.length;
        while (n > 1 && digits[n - 1] == '0')
            n--;
        return sign ~ ctNum(whole) ~ "." ~ digits[0 .. n].idup;
    }
    return formatG17(v);
}

private string formatG17(double v) @trusted nothrow
{
    import core.stdc.stdio : snprintf;

    char[40] t;
    // sound: snprintf writes at most t.length bytes and returns the length without the terminator
    auto n = snprintf(t.ptr, t.length, "%.17g", v);
    return t[0 .. n].idup;
}

unittest
{
    assert(ctNum(0) == "0" && ctNum(1234567890123) == "1234567890123");
    assert(itoa(-5) == "-5" && itoa(long.min) == "-9223372036854775808" && itoa(7) == "7");
    assert(numText(150) == "150" && numText(-3) == "-3");
    assert(numText(0.5) == "0.5");
    enum ct = numText(2.25);
    static assert(ct == "2.25");
    static assert(numText(-0.5) == "-0.5");
}
