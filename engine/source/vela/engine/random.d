/// Random bytes from the kernel (getrandom(2)): WebSocket masking keys and handshake nonces, and `vela:crypto`'s
/// `randomBytes` (salts, keys, tokens).
module vela.engine.random;

@safe:

import core.stdc.errno : errno, EINTR;

private extern (C) ptrdiff_t getrandom(void* buf, size_t len, uint flags) nothrow @nogc @system;

/// Fills `b` with cryptographically secure random bytes. Blocks only before the kernel's pool is first initialized (early
/// boot); throws `Exception` ("vela: getrandom failed") if the system call fails.
void randomBytes(scope ubyte[] b) @trusted
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
            throw new Exception("vela: getrandom failed");
        }
        got += n;
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
