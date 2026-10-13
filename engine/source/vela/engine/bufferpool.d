/// Per-worker buffer pool on the GC heap (blocks the collector never scans: `NO_SCAN`).
///
/// Slices of these buffers reach user code (the request body, header values, `const(char)[]` parameters). The memory is
/// the GC's, not malloc's, so a slice a handler keeps after the request is memory-safe: it keeps its block alive. It may
/// show bytes of a later request that reused the buffer; that is a bug in the user's code, not memory corruption.
///
/// Fixed size classes (4, 16, 64 KiB). Idle connections return their buffer to the pool: 10 thousand idle keep-alive
/// connections do not hold 160 MiB. The pool keeps at most `maxCachedBytes`; the excess is simply dropped (nothing is
/// ever freed by hand: a user slice may still point into it) and the collector reclaims it.
/// Larger requests (a body up to `Limits.maxBodyBytes`) get an exact-size buffer that is never cached: it becomes garbage
/// as soon as the request is done and no slice of it survives.
/// Single-threaded by design (one pool per worker), hence no locks.
module vela.engine.bufferpool;

@safe:

import vela.http.buffer : allocBlock;

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

    /// Lends a buffer with at least `minSize` bytes.
    Buffer acquire(size_t minSize) @trusted nothrow
    {
        ubyte c = 0;
        while (c < classSize.length && classSize[c] < minSize)
            c++;
        outstanding++;
        if (c == oversize)
            return Buffer((cast(ubyte*) allocBlock(minSize))[0 .. minSize], 0, oversize);
        if (free_[c].length)
        {
            auto m = free_[c][$ - 1];
            free_[c] = free_[c][0 .. $ - 1];
            cachedBytes -= m.length;
            return Buffer(m, 0, c);
        }
        return Buffer((cast(ubyte*) allocBlock(classSize[c]))[0 .. classSize[c]], 0, c);
    }

    /// Gives it back. Above the ceiling (or when oversize) the buffer is just dropped for the collector.
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
        b = Buffer.init;
    }

    /// Forgets the cached buffers so the collector can reclaim them. Used after a burst, when the loop is quiet: cached
    /// page-sized blocks sit between the big ones of the burst and keep their GC pools from being returned to the OS.
    /// The cache refills on demand.
    void dropCache() nothrow
    {
        foreach (ref list; free_)
            list = null;
        cachedBytes = 0;
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
