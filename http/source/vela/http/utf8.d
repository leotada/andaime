/// UTF-8 validation and counting, by hand (no std.utf in the core).
module vela.http.utf8;

@safe:

/// True if `s` is well-formed UTF-8 (RFC 3629): no overlong forms, no surrogates (U+D800..U+DFFF), nothing above
/// U+10FFFF, no stray continuation bytes.
bool validUtf8(scope const(char)[] s) pure nothrow @nogc
{
    size_t i = 0;
    while (i < s.length)
    {
        immutable ubyte c = s[i];
        if (c < 0x80)
        {
            i++;
            continue;
        }
        size_t n;      // continuation bytes
        uint cp;
        uint minCp;
        if (c >= 0xC2 && c <= 0xDF) { n = 1; cp = c & 0x1F; minCp = 0x80; }
        else if (c >= 0xE0 && c <= 0xEF) { n = 2; cp = c & 0x0F; minCp = 0x800; }
        else if (c >= 0xF0 && c <= 0xF4) { n = 3; cp = c & 0x07; minCp = 0x10000; }
        else return false; // 0x80..0xC1 (continuation / overlong lead) and 0xF5..0xFF
        if (s.length - i <= n)
            return false;
        foreach (k; 1 .. n + 1)
        {
            immutable ubyte d = s[i + k];
            if ((d & 0xC0) != 0x80)
                return false;
            cp = (cp << 6) | (d & 0x3F);
        }
        if (cp < minCp || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
            return false;
        i += n + 1;
    }
    return true;
}

/// Number of code points in `s`, assuming it is valid UTF-8 (counts the bytes that are not continuation bytes).
size_t codePoints(scope const(char)[] s) pure nothrow @nogc
{
    size_t n;
    foreach (char c; s)
        if ((c & 0xC0) != 0x80)
            n++;
    return n;
}

unittest
{
    assert(validUtf8("") && validUtf8("abc") && validUtf8("çã") && validUtf8("€") && validUtf8("\U0001F600"));
    assert(!validUtf8("\xff") && !validUtf8("\x80") && !validUtf8("\xc3") && !validUtf8("\xc3(") && !validUtf8("\xc0\x80"));
    assert(!validUtf8("\xed\xa0\x80"), "surrogate");
    assert(!validUtf8("\xe0\x80\x80"), "overlong 3 bytes");
    assert(!validUtf8("\xf4\x90\x80\x80"), "above U+10FFFF");
    assert(!validUtf8("\xf0\x80\x80\x80"), "overlong 4 bytes");
    assert(codePoints("çã") == 2 && "çã".length == 4);
    assert(codePoints("a\U0001F600") == 2 && codePoints("") == 0);
}
