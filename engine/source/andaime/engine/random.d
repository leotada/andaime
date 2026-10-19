/// Random bytes from the kernel (getrandom(2)): WebSocket masking keys and handshake nonces, and `andaime:crypto`'s
/// `randomBytes` (salts, keys, tokens).
module andaime.engine.random 2025;

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

import andaime.values.uuid : Uuid;

/// A random (version 4) UUID from the system's secure generator.
Uuid uuid4()
{
    ubyte[16] r;
    randomBytes(r[]);
    return Uuid.v4(r);
}

/// A time-ordered (version 7) UUID: the current Unix time in milliseconds, then random bits. Within one millisecond the
/// 12 bits after the time are a counter (RFC 9562, section 6.2, method 1) started at a random value below 2048, so the
/// UUIDs one thread creates always increase; when the counter runs out, the time moves on by one millisecond.
Uuid uuid7()
{
    ubyte[10] r;
    randomBytes(r[]);
    long ms = unixMillisNow();
    if (ms <= v7LastMs)
    {
        ms = v7LastMs;
        if (++v7Counter > 0xFFF)
        {
            ms++;
            v7Counter = (r[0] << 8 | r[1]) & 0x7FF;
        }
    }
    else
        v7Counter = (r[0] << 8 | r[1]) & 0x7FF;
    v7LastMs = ms;
    r[0] = cast(ubyte)(v7Counter >> 8); // `v7` keeps the low nibble of r[0] under the version
    r[1] = cast(ubyte) v7Counter;
    return Uuid.v7(ms, r);
}

private long v7LastMs; // per thread: the order holds among one thread's UUIDs
private int v7Counter;

/// Milliseconds since the Unix epoch, from the wall clock.
private long unixMillisNow() @trusted
{
    // @trusted: the clock calls only write the struct on the stack they are given
    version (Posix)
    {
        import core.sys.posix.sys.time : gettimeofday, timeval; // clock_gettime is not in druntime's macOS bindings

        timeval tv;
        gettimeofday(&tv, null);
        return cast(long) tv.tv_sec * 1000 + tv.tv_usec / 1000;
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : FILETIME, GetSystemTimeAsFileTime;

        FILETIME ft;
        GetSystemTimeAsFileTime(&ft);
        immutable ulong t = (cast(ulong) ft.dwHighDateTime << 32) | ft.dwLowDateTime; // 100 ns since 1601
        return cast(long)((t - 116_444_736_000_000_000UL) / 10_000);
    }
    else
        static assert(0, "andaime: no wall clock for uuid7 on this platform");
}

unittest
{
    auto a = uuid4(), b = uuid4();
    assert(a != b && a.version_ == 4 && a.isRfc9562);

    Uuid prev = uuid7();
    assert(prev.version_ == 7 && prev.isRfc9562);
    immutable long now = unixMillisNow();
    assert(prev.unixMillis <= now && now - prev.unixMillis < 5_000);
    foreach (i; 0 .. 5000) // many in one millisecond: the counter keeps them increasing
    {
        auto u = uuid7();
        assert(u > prev, "uuid7 must increase on one thread");
        prev = u;
    }
}
