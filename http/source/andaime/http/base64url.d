/// base64url (RFC 4648 §5) without padding: the HTTP2-Settings header, JWS/JWT, Web Push keys, URL-safe tokens.
/// Standard base64 (with padding) is in `andaime.http.sha1`.
module andaime.http.base64url;

@safe:

import andaime.http.buffer : ByteBuffer;

private immutable char[64] alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Length of the unpadded base64url encoding of `n` bytes.
size_t base64UrlLength(size_t n) pure nothrow @nogc => n / 3 * 4 + (n % 3 == 0 ? 0 : n % 3 + 1);

/// base64url of `src` without padding, into `dst` (at least `base64UrlLength(src.length)` chars); returns the used part.
char[] base64UrlEncode(scope const(ubyte)[] src, return char[] dst) pure nothrow @nogc
{
    assert(dst.length >= base64UrlLength(src.length), "andaime: base64url output too small");
    size_t o = 0, i = 0;
    for (; i + 3 <= src.length; i += 3)
    {
        immutable uint v = src[i] << 16 | src[i + 1] << 8 | src[i + 2];
        dst[o++] = alphabet[v >> 18];
        dst[o++] = alphabet[(v >> 12) & 63];
        dst[o++] = alphabet[(v >> 6) & 63];
        dst[o++] = alphabet[v & 63];
    }
    immutable rest = src.length - i;
    if (rest)
    {
        immutable uint v = src[i] << 16 | (rest == 2 ? src[i + 1] << 8 : 0);
        dst[o++] = alphabet[v >> 18];
        dst[o++] = alphabet[(v >> 12) & 63];
        if (rest == 2)
            dst[o++] = alphabet[(v >> 6) & 63];
    }
    return dst[0 .. o];
}

/// base64url of `src` without padding, as a new string.
string base64UrlEncode(scope const(ubyte)[] src) pure nothrow
{
    auto d = new char[base64UrlLength(src.length)];
    base64UrlEncode(src, d);
    return (() @trusted => cast(string) d)(); // sole owner: safe to make immutable
}

private int value(char c) pure nothrow @nogc
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-') return 62;
    if (c == '_') return 63;
    return -1;
}

/// Lenient decoding into `o`: stops at the first `=` (padding is tolerated, not required) and ignores leftover bits.
/// False on a character outside the alphabet. (The HTTP2-Settings header, RFC 7540 §3.2.1.)
bool decodeBase64Url(scope const(char)[] s, ref ByteBuffer o) nothrow @nogc
{
    uint acc = 0, bits = 0;
    foreach (c; s)
    {
        if (c == '=')
            break;
        immutable v = value(c);
        if (v < 0)
            return false;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            o.put(cast(char)((acc >> bits) & 0xff));
        }
    }
    return true;
}

/// Strict decoding: unpadded base64url only, as produced by `base64UrlEncode` (no `=`, no length that cannot occur, no
/// set bits after the last byte). False when `s` is not valid.
bool base64UrlDecode(scope const(char)[] s, out ubyte[] result) pure nothrow
{
    if (s.length % 4 == 1)
        return false;
    auto o = new ubyte[s.length / 4 * 3 + (s.length % 4 == 0 ? 0 : s.length % 4 - 1)];
    uint acc = 0, bits = 0;
    size_t n = 0;
    foreach (c; s)
    {
        immutable v = value(c);
        if (v < 0)
            return false;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            o[n++] = cast(ubyte)((acc >> bits) & 0xff);
        }
    }
    if (acc & ((1u << bits) - 1)) // non-canonical: bits left over that are not zero
        return false;
    result = o;
    return true;
}

unittest
{
    // RFC 4648 §10 vectors, without padding, and the URL-safe characters
    static immutable string[2][] vec = [["", ""], ["f", "Zg"], ["fo", "Zm8"], ["foo", "Zm9v"], ["foob", "Zm9vYg"],
        ["fooba", "Zm9vYmE"], ["foobar", "Zm9vYmFy"], ["\xfb\xff\xbf", "-_-_"]];
    foreach (v; vec)
    {
        auto bytes = cast(const(ubyte)[]) v[0];
        ubyte[] d;
        assert(base64UrlEncode(bytes) == v[1], v[1]);
        assert(base64UrlDecode(v[1], d) && d == bytes, v[1]);
        assert(base64UrlLength(bytes.length) == v[1].length);
    }
    ubyte[] d;
    foreach (bad; ["Zg==", "Z", "Zh", "a+b/", "Zm9v Yg"])
        assert(!base64UrlDecode(bad, d), bad);

    ByteBuffer b;
    assert(decodeBase64Url("Zm9vYg==", b) && b.data == "foob");
    b.clear();
    assert(!decodeBase64Url("Zm9v+", b));
}
