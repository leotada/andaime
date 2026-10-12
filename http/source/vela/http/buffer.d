/// Growable byte buffer allocated outside the GC heap.
/// It holds no pointers into the GC, so the collector never scans it.
module vela.http.buffer;

import core.stdc.stdlib : malloc, realloc, free;
import core.exception : onOutOfMemoryError;

struct ByteBuffer
{
    private char* ptr;
    private size_t len;
    private size_t cap;

    @disable this(this); // single owner: avoids double free

    ~this() @trusted nothrow @nogc
    {
        free(ptr);
    }

    size_t length() const pure nothrow @nogc @safe => len;
    size_t capacity() const pure nothrow @nogc @safe => cap;

    /// Slice valid until the next write or `clear`.
    const(char)[] data() const pure nothrow @nogc @trusted return
    {
        return ptr[0 .. len];
    }

    void clear() pure nothrow @nogc @safe
    {
        len = 0;
    }

    void reserve(size_t extra) nothrow @nogc @trusted
    {
        if (len + extra <= cap)
            return;
        size_t n = cap ? cap : 256;
        while (n < len + extra)
            n *= 2;
        auto p = cast(char*) realloc(ptr, n);
        if (p is null)
            onOutOfMemoryError();
        ptr = p;
        cap = n;
    }

    void put(scope const(char)[] s) nothrow @nogc @trusted
    {
        reserve(s.length);
        ptr[len .. len + s.length] = s[];
        len += s.length;
    }

    /// `n` bytes of free space at the end of the buffer, to write into directly (read(2), pread...).
    /// Then call `commit(k)` with how many bytes were actually written.
    char[] writable(size_t n) nothrow @nogc @trusted
    {
        reserve(n);
        return ptr[len .. len + n];
    }

    void commit(size_t n) nothrow @nogc @safe
    {
        assert(len + n <= cap, "vela: commit beyond the reserved space");
        len += n;
    }

    void put(char c) nothrow @nogc @trusted
    {
        reserve(1);
        ptr[len++] = c;
    }

    /// Decimal integer without std.conv and without allocating.
    void putInt(long v) nothrow @nogc @safe
    {
        char[20] tmp = void;
        size_t i = tmp.length;
        ulong u = v < 0 ? (cast(ulong)(-(v + 1))) + 1 : cast(ulong) v;
        do
        {
            tmp[--i] = cast(char)('0' + u % 10);
            u /= 10;
        }
        while (u);
        if (v < 0)
            put('-');
        put(tmp[i .. $]);
    }

    void putUint(ulong u) nothrow @nogc @safe
    {
        char[20] tmp = void;
        size_t i = tmp.length;
        do
        {
            tmp[--i] = cast(char)('0' + u % 10);
            u /= 10;
        }
        while (u);
        put(tmp[i .. $]);
    }

    /// Short round-trip format (%.17g). NaN/Inf become `null` (JSON).
    void putFloat(double d) nothrow @nogc @trusted
    {
        import core.stdc.stdio : snprintf;

        if (d != d || d == double.infinity || d == -double.infinity)
        {
            put("null");
            return;
        }
        char[32] tmp = void;
        int n = snprintf(tmp.ptr, tmp.length, "%.17g", d);
        put(tmp[0 .. n]);
    }

    /// Returns memory if the buffer grew beyond `maxKeep` (e.g. after
    /// a large response), so RSS does not stay pinned to the peak.
    void shrinkTo(size_t maxKeep) nothrow @nogc @trusted
    {
        if (cap <= maxKeep)
            return;
        free(ptr);
        ptr = null;
        len = cap = 0;
    }
}

unittest
{
    ByteBuffer b;
    b.put("x=");
    b.putInt(-1234);
    b.put(' ');
    b.putInt(long.min);
    b.put(' ');
    b.putFloat(0.5);
    assert(b.data == "x=-1234 -9223372036854775808 0.5", b.data);
    b.clear();
    assert(b.length == 0 && b.capacity >= 32);
}
