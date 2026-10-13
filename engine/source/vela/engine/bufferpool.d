/// Per-worker buffer pool, outside the GC heap.
///
/// Fixed size classes (4, 16, 64 KiB). Idle connections return their
/// buffer to the pool: 10 thousand idle keep-alive connections do not hold 160 MiB.
/// The pool keeps at most `maxCachedBytes`; the excess goes back to the OS.
/// Larger requests (a body up to `Limits.maxBodyBytes`) get an exact-size buffer that is never
/// cached: it goes back to the OS as soon as the request is done.
/// Single-threaded by design (one pool per worker), hence no locks.
module vela.engine.bufferpool;

@safe:

import core.stdc.stdlib : malloc, free;
import core.exception : onOutOfMemoryError;

struct Buffer
{
    ubyte[] mem; /// total capacity
    size_t len;  /// valid bytes
    ubyte cls;   /// size class (to return it to the right pool)

    bool isNull() const nothrow @nogc @safe => mem.length == 0;
    ubyte[] data() nothrow @nogc @safe return => mem[0 .. len];
    ubyte[] free_() nothrow @nogc @safe return => mem[len .. $];

    /// Moves the not-yet-consumed bytes to the start (after parsing
    /// a pipelined request). Keeps the head contiguous for the parser.
    void compact(size_t consumed) nothrow @nogc @trusted
    {
        import core.stdc.string : memmove;

        immutable rest = len - consumed;
        if (rest && consumed)
            memmove(mem.ptr, mem.ptr + consumed, rest);
        len = rest;
    }
}

struct BufferPool
{
    static immutable size_t[3] classSize = [4 << 10, 16 << 10, 64 << 10];
    /// `Buffer.cls` of a buffer larger than every class.
    enum ubyte oversize = classSize.length;

    private ubyte[][][3] free_;
    private size_t cachedBytes;
    size_t maxCachedBytes = 2 << 20; /// per-worker cache ceiling (2 MiB)
    size_t outstanding;              /// buffers currently lent out (metric)

    @disable this(this);

    ~this() @trusted nothrow @nogc
    {
        foreach (ref list; free_)
            foreach (b; list)
                free(b.ptr);
    }

    /// Lends a buffer with at least `minSize` bytes.
    Buffer acquire(size_t minSize) @trusted nothrow
    {
        ubyte c = 0;
        while (c < classSize.length && classSize[c] < minSize)
            c++;
        outstanding++;
        if (c == oversize)
        {
            auto big = cast(ubyte*) malloc(minSize);
            if (big is null)
                onOutOfMemoryError();
            return Buffer(big[0 .. minSize], 0, oversize);
        }
        if (free_[c].length)
        {
            auto m = free_[c][$ - 1];
            free_[c] = free_[c][0 .. $ - 1];
            cachedBytes -= m.length;
            return Buffer(m, 0, c);
        }
        auto p = cast(ubyte*) malloc(classSize[c]);
        if (p is null)
            onOutOfMemoryError();
        return Buffer(p[0 .. classSize[c]], 0, c);
    }

    /// Gives it back. Above the ceiling, frees it straight to the OS.
    void release(ref Buffer b) @trusted nothrow
    {
        if (b.isNull)
            return;
        outstanding--;
        if (b.cls != oversize && cachedBytes + b.mem.length <= maxCachedBytes)
        {
            free_[b.cls] ~= b.mem; // the list itself is small and stable after warm-up
            cachedBytes += b.mem.length;
        }
        else
            free(b.mem.ptr);
        b = Buffer.init;
    }

    /// Moves the data to a buffer of at least `minSize` bytes (the next class, or an exact-size
    /// one for a large body). The caller enforces the limits (`Limits`).
    bool grow(ref Buffer b, size_t minSize) @trusted nothrow
    {
        auto nb = acquire(minSize);
        nb.mem[0 .. b.len] = b.mem[0 .. b.len];
        nb.len = b.len;
        release(b);
        b = nb;
        return true;
    }
}

@trusted unittest // compares raw buffer addresses
{
    BufferPool pool;
    auto a = pool.acquire(100);
    assert(a.mem.length == 4096 && pool.outstanding == 1);
    a.mem[0 .. 3] = cast(ubyte[]) "abc";
    a.len = 3;
    assert(pool.grow(a, 10_000) && a.mem.length == 16 << 10 && a.data == cast(ubyte[]) "abc");
    auto p = a.mem.ptr;
    pool.release(a);
    assert(a.isNull && pool.outstanding == 0);
    auto b = pool.acquire(5000);
    assert(b.mem.ptr is p); // reused, no malloc
    pool.release(b);

    // above the largest class: exact size, data preserved, never cached
    auto big = pool.acquire(100);
    big.mem[0 .. 3] = cast(ubyte[]) "xyz";
    big.len = 3;
    assert(pool.grow(big, 1_000_000) && big.mem.length == 1_000_000 && big.cls == BufferPool.oversize);
    assert(big.data == cast(ubyte[]) "xyz");
    immutable cached = pool.cachedBytes;
    pool.release(big);
    assert(pool.cachedBytes == cached && pool.outstanding == 0);
}
