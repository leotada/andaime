/// `Uuid`: a 128-bit identifier (RFC 9562), as a value. It is a text type (`andaime.http.texttype`), so it works as a
/// path or query parameter, in JSON and as a `uuid` column with `rowsAs`, and OpenAPI says `format: uuid`.
///
/// Building one needs randomness and, for v7, the clock: those are effects, so this module only assembles the bits from
/// what it is given (`Uuid.v4(random)`, `Uuid.v7(unixMs, random)`). `andaime.engine.random` has `uuid4()` and `uuid7()`
/// over the system's generator; a domain takes them through a port.
module andaime.values.uuid 2025;

@safe:

/// A UUID. `Uuid.init` is the nil UUID (all zeros).
struct Uuid
{
    ubyte[16] bytes;

    enum openApiFormat = "uuid";
    enum invalidMessage = "expected a UUID (8-4-4-4-12 hexadecimal digits)";

    /// Version 4: random. `random` supplies the bits; 6 of them are replaced by the version and the variant.
    static Uuid v4(scope const ref ubyte[16] random) pure nothrow @nogc
    {
        Uuid u;
        u.bytes = random;
        u.stamp(4);
        return u;
    }

    /// Version 7: the Unix time in milliseconds (48 bits, big-endian), then `random` (74 of its 80 bits are kept), so
    /// UUIDs created later sort after earlier ones: good primary keys.
    static Uuid v7(long unixMs, scope const ref ubyte[10] random) pure nothrow @nogc
    {
        Uuid u;
        foreach (i; 0 .. 6)
            u.bytes[i] = cast(ubyte)(unixMs >> (8 * (5 - i)));
        u.bytes[6 .. 16] = random[];
        u.stamp(7);
        return u;
    }

    /// The version (4 for random, 7 for time-ordered; 0 for the nil UUID).
    int version_() const pure nothrow @nogc => bytes[6] >> 4;

    /// True for the RFC 9562 variant (`10xx` in the top bits of byte 8), the one every generated UUID uses.
    bool isRfc9562() const pure nothrow @nogc => (bytes[8] & 0xC0) == 0x80;

    /// True for the nil UUID.
    bool isNil() const pure nothrow @nogc
    {
        foreach (b; bytes)
            if (b)
                return false;
        return true;
    }

    /// For a v7 UUID, its time: milliseconds since the Unix epoch.
    long unixMillis() const pure nothrow @nogc
    {
        long ms;
        foreach (i; 0 .. 6)
            ms = (ms << 8) | bytes[i];
        return ms;
    }

    /// Parses the canonical form, `8-4-4-4-12` hexadecimal digits, in either case.
    static bool fromString(scope const(char)[] s, out Uuid v) pure nothrow @nogc
    {
        if (s.length != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-')
            return false;
        size_t k;
        for (size_t i = 0; i < 36; i++)
        {
            if (i == 8 || i == 13 || i == 18 || i == 23)
                continue;
            immutable hi = hexValue(s[i]), lo = hexValue(s[i + 1]);
            if (hi < 0 || lo < 0)
                return false;
            v.bytes[k++] = cast(ubyte)(hi << 4 | lo);
            i++;
        }
        return true;
    }

    /// The canonical form, lowercase.
    void toString(scope void delegate(scope const(char)[]) @safe sink) const
    {
        char[36] t = text();
        sink(t[]);
    }

    /// ditto, as a new string.
    string toString() const pure nothrow
    {
        char[36] t = text();
        return t[].idup;
    }

    /// The canonical form in a fixed buffer (no allocation).
    char[36] text() const pure nothrow @nogc
    {
        static immutable char[16] digits = "0123456789abcdef";
        char[36] t;
        size_t k;
        foreach (i, b; bytes)
        {
            if (i == 4 || i == 6 || i == 8 || i == 10)
                t[k++] = '-';
            t[k++] = digits[b >> 4];
            t[k++] = digits[b & 15];
        }
        return t;
    }

    /// Byte order, which for v7 is creation order.
    int opCmp(scope const ref Uuid o) const pure nothrow @nogc
    {
        foreach (i; 0 .. 16)
            if (bytes[i] != o.bytes[i])
                return bytes[i] < o.bytes[i] ? -1 : 1;
        return 0;
    }

    private void stamp(int ver) pure nothrow @nogc
    {
        bytes[6] = cast(ubyte)((bytes[6] & 0x0F) | (ver << 4));
        bytes[8] = cast(ubyte)((bytes[8] & 0x3F) | 0x80);
    }
}

private int hexValue(char c) pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

// RFC 9562, Appendix A: the v4 and v7 examples
@safe unittest
{
    Uuid u;
    assert(Uuid.fromString("919108f7-52d1-4320-9bac-f847db4148a8", u));
    assert(u.version_ == 4 && u.isRfc9562 && u.toString == "919108f7-52d1-4320-9bac-f847db4148a8");
    ubyte[16] r4 = u.bytes;
    assert(Uuid.v4(r4) == u, "v4 keeps the bits and stamps version and variant");

    // unix_ts_ms 0x017F22E279B0, rand_a 0xCC3, rand_b 0x18C4DC0C0C07398F
    ubyte[10] r7 = [0x0C, 0xC3, 0x18, 0xC4, 0xDC, 0x0C, 0x0C, 0x07, 0x39, 0x8F];
    auto t = Uuid.v7(0x017F22E279B0, r7);
    assert(t.toString == "017f22e2-79b0-7cc3-98c4-dc0c0c07398f", t.toString);
    assert(t.version_ == 7 && t.isRfc9562 && t.unixMillis == 1_645_557_742_000);
    assert(Uuid.fromString("017F22E2-79B0-7CC3-98C4-DC0C0C07398F", u) && u == t, "uppercase parses");

    auto later = Uuid.v7(0x017F22E279B1, r7);
    assert(t < later && later > t && t.opCmp(t) == 0);
    assert(Uuid.init.isNil && Uuid.init.toString == "00000000-0000-0000-0000-000000000000");

    foreach (bad; ["", "919108f7-52d1-4320-9bac-f847db4148a", "919108f7-52d1-4320-9bac-f847db4148a8x",
            "919108f7x52d1-4320-9bac-f847db4148a8", "919108f7-52d1-4320-9bac-f847db4148ag", "919108f752d143209bacf847db4148a8"])
        assert(!Uuid.fromString(bad, u), bad);
}

@safe unittest
{
    import andaime.http.texttype : isTextType, textTypeFormat;

    static assert(isTextType!Uuid);
    static assert(textTypeFormat!Uuid == "uuid");
}
