/// SHA-256, HMAC-SHA256 and HKDF-SHA256 (RFC 5869).
module andaime.crypto.hash 2025;

@safe:

import andaime.crypto.common;
import andaime.crypto.libcrypto;

/// SHA-256 of `data`.
ubyte[32] sha256(scope const(ubyte)[] data)
{
    needLibcrypto();
    ubyte[32] o;
    uint n;
    // @trusted: EVP_Digest reads data.length bytes from data and writes at most 32 bytes (SHA-256) into o
    immutable ok = (() @trusted => lc.EVP_Digest(data.ptr, data.length, o.ptr, &n, lc.EVP_sha256(), null))();
    need(ok == 1 && n == 32, "SHA-256 failed");
    return o;
}

/// ditto, for text.
ubyte[32] sha256(scope const(char)[] data) => sha256(cast(const(ubyte)[]) data);

/// HMAC-SHA256 of `data` with `key` (any length).
ubyte[32] hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] data)
{
    needLibcrypto();
    need(key.length <= int.max, "HMAC key too long");
    ubyte[32] o;
    uint n;
    // @trusted: HMAC reads key.length and data.length bytes and writes at most 32 bytes (SHA-256) into o
    auto p = (() @trusted => lc.HMAC(lc.EVP_sha256(), key.ptr, cast(int) key.length, data.ptr, data.length, o.ptr, &n))();
    need(p !is null && n == 32, "HMAC-SHA256 failed");
    return o;
}

/// ditto, for text.
ubyte[32] hmacSha256(scope const(char)[] key, scope const(char)[] data)
    => hmacSha256(cast(const(ubyte)[]) key, cast(const(ubyte)[]) data);

/// HKDF-Extract (RFC 5869 §2.2): the pseudorandom key from input keying material and a salt (empty: 32 zero bytes).
ubyte[32] hkdfExtract(scope const(ubyte)[] salt, scope const(ubyte)[] ikm)
{
    static immutable ubyte[32] zeros;
    return hmacSha256(salt.length ? salt : zeros[], ikm);
}

/// HKDF-Expand (RFC 5869 §2.3): `length` bytes (at most 255 * 32) of output keying material from `prk` and `info`.
ubyte[] hkdfExpand(scope const(ubyte)[] prk, scope const(ubyte)[] info, size_t length)
{
    need(length <= 255 * 32, "HKDF output longer than 8160 bytes");
    auto okm = new ubyte[length];
    ubyte[32] t;
    size_t have = 0, tLen = 0;
    ubyte counter = 1;
    auto block = new ubyte[32 + info.length + 1];
    while (have < length)
    {
        block[0 .. tLen] = t[0 .. tLen];
        block[tLen .. tLen + info.length] = info[];
        block[tLen + info.length] = counter++;
        t = hmacSha256(prk, block[0 .. tLen + info.length + 1]);
        tLen = 32;
        immutable take = length - have < 32 ? length - have : 32;
        okm[have .. have + take] = t[0 .. take];
        have += take;
    }
    return okm;
}

/// HKDF-SHA256 (RFC 5869): extract then expand.
ubyte[] hkdfSha256(scope const(ubyte)[] salt, scope const(ubyte)[] ikm, scope const(ubyte)[] info, size_t length)
{
    auto prk = hkdfExtract(salt, ikm);
    return hkdfExpand(prk[], info, length);
}
