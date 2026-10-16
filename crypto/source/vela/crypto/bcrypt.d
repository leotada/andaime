/// bcrypt password hashes (`$2b$`, compatible with Python's bcrypt and passlib, and with `$2a$`/`$2y$` hashes from
/// other systems), through libxcrypt's `crypt_rn` and `crypt_gensalt_rn`, loaded at run time.
///
/// Hashing is deliberately slow (cost 12 is ~250 ms of CPU): never call `bcryptHash`/`bcryptVerify` on the event loop.
/// From a handler use `bcryptHashOffload`/`bcryptVerifyOffload`, which run on the offload pool.
module vela.crypto.bcrypt;

@safe:

import vela.crypto.common;
import vela.engine.os : dlOpen, dlSym;

/// The default cost (2^12 rounds), passlib's and Python bcrypt's default.
enum uint bcryptDefaultCost = 12;

/// Hashes `password` with a fresh random salt: `$2b$12$` followed by 53 characters. Only the first 72 bytes of the
/// password count (a bcrypt limit; Python's bcrypt 4 and passlib behave the same). Throws `CryptoError` when libxcrypt is
/// missing, the cost is outside 4..31, or the password contains a NUL byte.
string bcryptHash(scope const(char)[] password, uint cost = bcryptDefaultCost)
{
    need(cost >= 4 && cost <= 31, "the bcrypt cost goes from 4 to 31");
    need(!hasNul(password), "a bcrypt password cannot contain a NUL byte");
    needLibxcrypt();
    char[64] setting;
    auto salt = randomBytes(16);
    auto s = gensalt(cost, salt, setting);
    need(s.length > 0, "crypt_gensalt_rn failed");
    auto h = cryptRn(password, s);
    need(h.length == 60, "bcrypt hashing failed");
    return h;
}

/// Whether `password` matches `hash` (a `$2b$`, `$2a$` or `$2y$` bcrypt hash). False for a wrong password and for a
/// malformed hash; the comparison takes the same time wherever the hashes differ.
bool bcryptVerify(scope const(char)[] password, scope const(char)[] hash)
{
    if (hash.length != 60 || hash[0] != '$' || hash[1] != '2' || !(hash[2] == 'a' || hash[2] == 'b' || hash[2] == 'y')
        || hash[3] != '$' || hasNul(password) || hasNul(hash))
        return false;
    needLibxcrypt();
    auto h = cryptRn(password, hash);
    return h.length == 60 && constantTimeEquals(h, hash);
}

/// `bcryptHash` on the offload pool: the calling fiber waits, the worker keeps serving. Throws `PoolSaturated` when the
/// pool's queue is full (see `vela.engine.offload`). Outside a request it runs inline.
string bcryptHashOffload(scope const(char)[] password, uint cost = bcryptDefaultCost)
{
    import vela.engine.offload : offload;

    auto p = password.idup;
    return offload(() => bcryptHash(p, cost));
}

/// `bcryptVerify` on the offload pool.
bool bcryptVerifyOffload(scope const(char)[] password, scope const(char)[] hash)
{
    import vela.engine.offload : offload;

    auto p = password.idup, h = hash.idup;
    return offload(() => bcryptVerify(p, h));
}

/// Whether libxcrypt (with bcrypt support) can be loaded.
bool bcryptAvailable() nothrow
{
    try
        return loadLibxcrypt() is null;
    catch (Exception)
        return false;
}

private bool hasNul(scope const(char)[] s) pure nothrow @nogc
{
    foreach (c; s)
        if (c == 0)
            return true;
    return false;
}

// ------------------------------------------------------------ libxcrypt

/// Function table in a struct held by a `__gshared` instance (see AGENTS.md, Pitfalls).
private struct CryptApi
{
    extern (C) nothrow @nogc:
    char* function(const(char)*, const(char)*, void*, int) crypt_rn;
    char* function(const(char)*, ulong, const(char)*, int, char*, int) crypt_gensalt_rn;
}

private __gshared CryptApi xc;
private __gshared bool xcLoaded;
private __gshared string xcError;
private __gshared Object xcLock;

shared static this() @trusted
{
    xcLock = new Object;
}

/// The size of libxcrypt's `struct crypt_data`, the scratch space `crypt_rn` needs (zeroed before the first use).
private enum int cryptDataSize = 32_768;

private string loadLibxcrypt() @trusted
{
    // @trusted: dlopen/dlsym with NUL-terminated literals; each pointer is cast to its declared prototype
    synchronized (xcLock)
    {
        if (xcLoaded)
            return null;
        if (xcError !is null)
            return xcError;

        version (linux)
            immutable string[] names = ["libcrypt.so.1\0", "libcrypt.so.2\0", "libcrypt.so\0"];
        else version (OSX)
            immutable string[] names = [
                "libcrypt.2.dylib\0",
                "libcrypt.dylib\0",
                "/opt/homebrew/lib/libcrypt.dylib\0",
                "/usr/local/lib/libcrypt.dylib\0"
            ];
        else version (Windows)
            immutable string[] names = ["libcrypt-2.dll\0", "libcrypt.dll\0", "crypt.dll\0"];

        void* h;
        foreach (n; names)
        {
            h = dlOpen(n.ptr);
            if (h !is null && dlSym(h, "crypt_rn\0".ptr) !is null && dlSym(h, "crypt_gensalt_rn\0".ptr) !is null)
                break;
            h = null;
        }
        if (h is null)
            return xcError = "vela.crypto: libxcrypt (libcrypt) not found; install libxcrypt";
        xc.crypt_rn = cast(typeof(xc.crypt_rn)) dlSym(h, "crypt_rn\0".ptr);
        xc.crypt_gensalt_rn = cast(typeof(xc.crypt_gensalt_rn)) dlSym(h, "crypt_gensalt_rn\0".ptr);
        xcLoaded = true;
        return null;
    }
}

private void needLibxcrypt()
{
    if (auto err = loadLibxcrypt())
        throw new CryptoError(err);
}

// @trusted: the salt is 16 bytes read by length; libxcrypt writes at most out.length bytes (NUL-terminated) into out
private const(char)[] gensalt(uint cost, scope const(ubyte)[] salt, return ref char[64] o) @trusted
{
    auto p = xc.crypt_gensalt_rn("$2b$", cost, cast(const(char)*) salt.ptr, cast(int) salt.length, o.ptr, cast(int) o.length);
    if (p is null)
        return null;
    size_t n;
    while (n < o.length && o[n])
        n++;
    return o[0 .. n];
}

// @trusted: phrase and setting are copied into NUL-terminated GC buffers; crypt_rn writes only inside the zeroed
// cryptDataSize-byte scratch it is given and returns a NUL-terminated string inside it (or null), copied out here
private string cryptRn(scope const(char)[] phrase, scope const(char)[] setting) @trusted
{
    auto zp = new char[phrase.length + 1];
    zp[0 .. phrase.length] = phrase[];
    zp[$ - 1] = 0;
    auto zs = new char[setting.length + 1];
    zs[0 .. setting.length] = setting[];
    zs[$ - 1] = 0;
    auto data = new ubyte[cryptDataSize];
    auto r = xc.crypt_rn(zp.ptr, zs.ptr, data.ptr, cryptDataSize);
    scope (exit)
        data[] = 0; // the scratch held the password
    zp[] = 0;
    if (r is null || r[0] == '*')
        return null;
    size_t n;
    while (r[n])
        n++;
    return r[0 .. n].idup;
}
