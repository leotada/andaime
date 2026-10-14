/// Growable byte buffer on the GC heap, in blocks the collector never scans (`NO_SCAN`: they hold no pointers).
///
/// Why the GC and not malloc: slices of these buffers reach user code (the request body, header values, a response body a
/// middleware looks at after the handler). With malloc/free or realloc, a slice kept past the request -- which `@safe`
/// code is allowed to do -- would point into freed memory. With the GC a kept slice keeps its block alive: it is
/// memory-safe, though it may show bytes from a later request that reused the block (a logic bug in user code, not
/// memory corruption).
///
/// Growing therefore allocates a new block, copies, and drops the old one; the old one is never freed explicitly because
/// a slice of it may still be in use. Buffers are reused (`clear`), so after warm-up requests do not grow them and the
/// hot path stays free of GC allocation (tests/alloc).
module vela.http.buffer;

@safe:

import core.memory : GC;
import core.exception : onOutOfMemoryError;

/// A `NO_SCAN` GC block of `n` bytes (internal: used by ByteBuffer and the engine's BufferPool). `@nogc` is asserted here on purpose, through a function-pointer cast: the
/// functions that write into a ByteBuffer are `@nogc` because they do not allocate once the buffer has warmed up; growth
/// (an amortized, warm-up-only event) is the single exception, and it lives in this one function.
/// Not `NO_INTERIOR`: user code holds slices into the middle of blocks.
char* allocBlock(size_t n) nothrow @nogc @trusted
{
    alias Malloc = extern (C) void* function(size_t, uint, const TypeInfo) pure nothrow @nogc;
    // sound: GC.malloc really is nothrow; @nogc only describes the GC's own bookkeeping, not memory safety
    auto p = cast(char*) (cast(Malloc) &GC.malloc)(n, GC.BlkAttr.NO_SCAN, null);
    if (p is null)
        onOutOfMemoryError();
    return p;
}

struct ByteBuffer
{
    private char* ptr;
    private size_t len;
    private size_t cap;

    @disable this(this); // single owner for writes

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

    /// Exchanges contents with `other` (hands a response to another owner without copying).
    void swap(ref ByteBuffer other) pure nothrow @nogc @safe
    {
        auto p = ptr; ptr = other.ptr; other.ptr = p;
        auto l = len; len = other.len; other.len = l;
        auto c = cap; cap = other.cap; other.cap = c;
    }

    void reserve(size_t extra) nothrow @nogc @trusted
    {
        if (len + extra <= cap)
            return;
        size_t n = cap ? cap : 256;
        while (n < len + extra)
            n *= 2;
        auto p = allocBlock(n);
        if (len)
            p[0 .. len] = ptr[0 .. len]; // the old block stays valid for whoever still holds a slice of it
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

    /// Drops the last `n` bytes.
    void trimEnd(size_t n) nothrow @nogc @safe
    {
        assert(n <= len, "vela: trimEnd beyond the data");
        len -= n;
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

    /// Drops the block if the buffer grew beyond `maxKeep` (e.g. after a large response), so memory does not stay
    /// pinned to the peak. The collector reclaims it once no slice refers to it.
    void shrinkTo(size_t maxKeep) nothrow @nogc @safe
    {
        if (cap <= maxKeep)
            return;
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
