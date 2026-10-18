/// Random bytes from the kernel (getrandom(2)): WebSocket masking keys and handshake nonces, and `andaime:crypto`'s
/// `randomBytes` (salts, keys, tokens).
module andaime.engine.random;

@safe:

version (linux)
{
    import core.stdc.errno : errno, EINTR;
    private extern (C) ptrdiff_t getrandom(void* buf, size_t len, uint flags) nothrow @nogc @system;
}
else version (OSX)
{
    private extern (C) void arc4random_buf(void* buf, size_t nbytes) nothrow @nogc @system;
}
else version (Posix)
{
    private extern (C) void arc4random_buf(void* buf, size_t nbytes) nothrow @nogc @system;
}
else version (Windows)
{
    pragma(lib, "bcrypt");
    private extern (Windows) nothrow @nogc @system
    int BCryptGenRandom(void* hAlgorithm, ubyte* pbBuffer, uint cbBuffer, uint dwFlags);
    private enum BCRYPT_USE_SYSTEM_PREFERRED_RNG = 0x00000002;
}

/// Fills `b` with cryptographically secure random bytes. Blocks only before the kernel's pool is first initialized (early
/// boot); throws `Exception` ("andaime: random failed") if the system call fails.
void randomBytes(scope ubyte[] b) @trusted
{
    if (b.length == 0)
        return;

    version (linux)
    {
        // @trusted: getrandom writes at most b.length - got bytes at b.ptr + got, inside b
        size_t got;
        while (got < b.length)
        {
            immutable n = getrandom(b.ptr + got, b.length - got, 0);
            if (n < 0)
            {
                if (errno == EINTR)
                    continue;
                throw new Exception("andaime: getrandom failed");
            }
            got += n;
        }
    }
    else version (OSX)
    {
        arc4random_buf(b.ptr, b.length);
    }
    else version (Posix)
    {
        arc4random_buf(b.ptr, b.length);
    }
    else version (Windows)
    {
        if (BCryptGenRandom(null, b.ptr, cast(uint) b.length, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
            throw new Exception("andaime: BCryptGenRandom failed");
    }
    else
    {
        throw new Exception("andaime: no secure random source available");
    }
}

unittest
{
    ubyte[32] a, b;
    randomBytes(a[]);
    randomBytes(b[]);
    assert(a != b);
    randomBytes(a[0 .. 0]);
}
