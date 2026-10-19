/// Text -> number without std.conv (compiles fast, does not allocate): the integer and floating-point readers of
/// query values, JSON numbers and `JsonValue`.
module andaime.http.numparse 2025;

@safe:

bool parseInteger(T)(scope const(char)[] s, out T v) pure nothrow @nogc
    if (__traits(isIntegral, T) && !is(T == bool))
{
    if (s.length == 0)
        return false;
    immutable bool neg = s[0] == '-';
    size_t i = neg ? 1 : 0;
    if (i == s.length)
        return false;
    static if (__traits(isUnsigned, T))
    {
        if (neg)
            return false;
        immutable ulong lim = T.max;
    }
    else
        immutable ulong lim = neg ? cast(ulong) T.max + 1 : cast(ulong) T.max;
    ulong acc = 0;
    for (; i < s.length; i++)
    {
        immutable char c = s[i];
        if (c < '0' || c > '9')
            return false;
        immutable uint d = c - '0';
        if (acc > (lim - d) / 10)
            return false; // overflow
        acc = acc * 10 + d;
    }
    v = neg ? cast(T) cast(long)(0UL - acc) : cast(T) acc;
    return true;
}

bool parseFloat(T)(scope const(char)[] s, out T v) nothrow @nogc @trusted
    if (__traits(isFloating, T))
{
    import core.stdc.stdlib : strtod;

    char[64] tmp = void;
    if (s.length == 0 || s.length >= tmp.length)
        return false;
    foreach (char c; s) // strtod accepts "inf", "0x1p3"...; JSON and query do not
        if (!((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E'))
            return false;
    tmp[0 .. s.length] = s[];
    tmp[s.length] = 0;
    char* end;
    immutable double d = strtod(tmp.ptr, &end);
    if (end != tmp.ptr + s.length)
        return false;
    v = cast(T) d;
    return true;
}
