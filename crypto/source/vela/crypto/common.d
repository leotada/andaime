/// What every `vela:crypto` module shares: the error type, loading libcrypto on first use, the random source.
module vela.crypto.common;

@safe:

import vela.crypto.libcrypto : loadLibcrypto;

/// Thrown when a primitive cannot run (OpenSSL or libxcrypt missing, a key of the wrong size, a library failure). Its
/// message starts with `vela.crypto:`. Authentication failures are not errors: `aes128GcmOpen`, `es256Verify` and
/// `bcryptVerify` return false.
class CryptoError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// Loads libcrypto if needed; throws `CryptoError` when it is not available.
package void needLibcrypto()
{
    if (auto err = loadLibcrypto())
        throw new CryptoError(err);
}

/// Whether OpenSSL 3's libcrypto can be loaded (tests skip when it cannot).
bool cryptoAvailable() nothrow
{
    try
        return loadLibcrypto() is null;
    catch (Exception)
        return false;
}

/// `n` cryptographically secure random bytes from the kernel (getrandom). For keys, salts, nonces and tokens.
ubyte[] randomBytes(size_t n)
{
    import random = vela.engine.random;

    auto b = new ubyte[n];
    random.randomBytes(b);
    return b;
}

/// Compares two byte strings in time that depends only on their lengths, not on where they differ: for MACs, tokens
/// and hashes. Different lengths compare unequal (the length is not secret).
bool constantTimeEquals(scope const(ubyte)[] a, scope const(ubyte)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    ubyte acc = 0;
    foreach (i; 0 .. a.length)
        acc |= a[i] ^ b[i];
    return acc == 0;
}

/// ditto, for text (tokens, hex digests).
bool constantTimeEquals(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
    => constantTimeEquals(cast(const(ubyte)[]) a, cast(const(ubyte)[]) b);

package void need(bool ok, lazy string what)
{
    if (!ok)
        throw new CryptoError("vela.crypto: " ~ what);
}

unittest
{
    assert(constantTimeEquals(cast(const(ubyte)[]) "abc", cast(const(ubyte)[]) "abc"));
    assert(!constantTimeEquals("abc", "abd") && !constantTimeEquals("abc", "ab") && constantTimeEquals("", ""));
    assert(randomBytes(32).length == 32 && randomBytes(16) != randomBytes(16));
}
