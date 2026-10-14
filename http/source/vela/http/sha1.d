/// SHA-1 (RFC 3174) and standard base64, by hand (no std.digest or std.base64 in the core).
/// Only the WebSocket handshake uses them (`Sec-WebSocket-Accept`), where SHA-1 is a fixed part of the protocol, not a
/// security measure.
module vela.http.sha1;

@safe:

/// Incremental SHA-1.
struct Sha1
{
    private uint[5] h = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    private ubyte[64] block;
    private size_t used;
    private ulong total;

    void put(scope const(ubyte)[] data) pure nothrow @nogc
    {
        total += data.length;
        while (data.length)
        {
            immutable n = data.length < 64 - used ? data.length : 64 - used;
            block[used .. used + n] = data[0 .. n];
            used += n;
            data = data[n .. $];
            if (used == 64)
            {
                compress();
                used = 0;
            }
        }
    }

    void put(scope const(char)[] data) pure nothrow @nogc @trusted
    {
        put(cast(const(ubyte)[]) data); // sound: same bytes, read only
    }

    ubyte[20] finish() pure nothrow @nogc
    {
        immutable ulong bits = total * 8;
        block[used++] = 0x80;
        if (used > 56)
        {
            block[used .. $] = 0;
            compress();
            used = 0;
        }
        block[used .. 56] = 0;
        foreach (i; 0 .. 8)
            block[56 + i] = cast(ubyte)(bits >> (56 - 8 * i));
        compress();
        ubyte[20] digest;
        foreach (i; 0 .. 5)
            foreach (k; 0 .. 4)
                digest[i * 4 + k] = cast(ubyte)(h[i] >> (24 - 8 * k));
        return digest;
    }

    private void compress() pure nothrow @nogc
    {
        static uint rotl(uint x, uint n) pure nothrow @nogc => (x << n) | (x >> (32 - n));

        uint[80] w = void;
        foreach (i; 0 .. 16)
            w[i] = (uint(block[i * 4]) << 24) | (uint(block[i * 4 + 1]) << 16) | (uint(block[i * 4 + 2]) << 8)
                | block[i * 4 + 3];
        foreach (i; 16 .. 80)
            w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
        uint a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
        foreach (i; 0 .. 80)
        {
            uint f, k;
            if (i < 20) { f = (b & c) | (~b & d); k = 0x5A827999; }
            else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1; }
            else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
            else { f = b ^ c ^ d; k = 0xCA62C1D6; }
            immutable t = rotl(a, 5) + f + e + k + w[i];
            e = d;
            d = c;
            c = rotl(b, 30);
            b = a;
            a = t;
        }
        h[0] += a;
        h[1] += b;
        h[2] += c;
        h[3] += d;
        h[4] += e;
    }
}

/// Length of the standard base64 encoding (with padding) of `n` bytes.
size_t base64Length(size_t n) pure nothrow @nogc => (n + 2) / 3 * 4;

/// Standard base64 (RFC 4648 §4, with padding) of `src` into `dst`, which must hold `base64Length(src.length)` chars.
/// Returns the encoded slice of `dst`.
char[] base64Encode(scope const(ubyte)[] src, return char[] dst) pure nothrow @nogc
{
    static immutable char[64] alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    assert(dst.length >= base64Length(src.length), "vela: base64 output too small");
    size_t o;
    size_t i;
    for (; i + 3 <= src.length; i += 3)
    {
        immutable uint v = (uint(src[i]) << 16) | (uint(src[i + 1]) << 8) | src[i + 2];
        dst[o++] = alphabet[v >> 18];
        dst[o++] = alphabet[(v >> 12) & 63];
        dst[o++] = alphabet[(v >> 6) & 63];
        dst[o++] = alphabet[v & 63];
    }
    if (i < src.length)
    {
        uint v = uint(src[i]) << 16;
        if (i + 1 < src.length)
            v |= uint(src[i + 1]) << 8;
        dst[o++] = alphabet[v >> 18];
        dst[o++] = alphabet[(v >> 12) & 63];
        dst[o++] = i + 1 < src.length ? alphabet[(v >> 6) & 63] : '=';
        dst[o++] = '=';
    }
    return dst[0 .. o];
}

unittest
{
    static string hex(const ubyte[20] d)
    {
        static immutable digits = "0123456789abcdef";
        char[40] s;
        foreach (i, b; d)
        {
            s[i * 2] = digits[b >> 4];
            s[i * 2 + 1] = digits[b & 15];
        }
        return s.idup;
    }

    static ubyte[20] sha(string s)
    {
        Sha1 h;
        h.put(s);
        return h.finish();
    }

    // RFC 3174 §7.3 test vectors
    assert(hex(sha("abc")) == "a9993e364706816aba3e25717850c26c9cd0d89d");
    assert(hex(sha("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
        == "84983e441c3bd26ebaae4aa1f95129e5e54670f1");
    assert(hex(sha("")) == "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    Sha1 m;
    foreach (i; 0 .. 1_000_000 / 50)
        m.put("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    assert(hex(m.finish()) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f");
    // the padding crosses a block boundary at 56 bytes; feeding in two parts must give the same digest
    foreach (n; [55, 56, 63, 64, 65])
    {
        char[65] buf = 'x';
        Sha1 a, b;
        a.put(buf[0 .. n]);
        b.put(buf[0 .. n / 2]);
        b.put(buf[n / 2 .. n]);
        assert(a.finish() == b.finish());
    }

    char[8] o;
    assert(base64Encode(cast(const(ubyte)[]) "", o) == "");
    assert(base64Encode(cast(const(ubyte)[]) "f", o) == "Zg==");
    assert(base64Encode(cast(const(ubyte)[]) "fo", o) == "Zm8=");
    assert(base64Encode(cast(const(ubyte)[]) "foo", o) == "Zm9v");
    assert(base64Encode(cast(const(ubyte)[]) "foob", o) == "Zm9vYg==");
    assert(base64Length(16) == 24 && base64Length(20) == 28);
}
