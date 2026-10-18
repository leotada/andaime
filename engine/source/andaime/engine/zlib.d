/// zlib loaded at run time (dlopen) for WebSocket compression (permessage-deflate, RFC 7692). No `-lz` at build time:
/// without libz.so.1 WebSockets simply are not compressed.
module andaime.engine.zlib;

@safe:

import core.stdc.config : c_ulong;
import andaime.engine.os : dlOpen, dlSym, dlError;
import andaime.http.buffer : ByteBuffer;
import andaime.http.optional : Optional;
import andaime.http.websocket : WsDeflate, InflateResult;

version (Windows)
    private enum zlibPkg = "zlib1.dll";
else version (OSX)
    private enum zlibPkg = "libz.1.dylib";
else
    private enum zlibPkg = "libz.so.1";

private:

/// zlib's z_stream (zlib.h); `uInt` is 32 bits and `uLong` is C's unsigned long (`c_ulong`).
struct ZStream
{
    const(ubyte)* next_in;
    uint avail_in;
    c_ulong total_in;
    ubyte* next_out;
    uint avail_out;
    c_ulong total_out;
    const(char)* msg;
    void* state;
    void* zalloc;
    void* zfree;
    void* opaque;
    int data_type;
    c_ulong adler;
    c_ulong reserved;
}

enum
{
    Z_OK = 0,
    Z_STREAM_END = 1,
    Z_BUF_ERROR = -5,
    Z_SYNC_FLUSH = 2,
    Z_DEFLATED = 8,
    Z_DEFAULT_STRATEGY = 0,
    Z_DEFAULT_COMPRESSION = -1,
}

/// Function table in a struct held by a `__gshared` instance: loose `extern (C)` variables would become global symbols
/// named like zlib's functions, which the library itself would then call.
struct Api
{
    extern (C) nothrow @nogc:
    const(char)* function() zlibVersion;
    int function(ZStream*, int level, int method, int windowBits, int memLevel, int strategy, const(char)* ver,
        int size) deflateInit2_;
    int function(ZStream*, int flush) deflate;
    int function(ZStream*) deflateReset;
    int function(ZStream*) deflateEnd;
    int function(ZStream*, int windowBits, const(char)* ver, int size) inflateInit2_;
    int function(ZStream*, int flush) inflate;
    int function(ZStream*) inflateReset;
    int function(ZStream*) inflateEnd;
}

__gshared Api z;
__gshared bool loaded, failed, warned;
__gshared string loadError;
__gshared Object gLock;

shared static this() @trusted
{
    gLock = new Object;
}

/// Loads libz once; false when it is not installed (or misses a symbol). Warns once on stderr when it fails.
bool loadZlib() @trusted
{
    synchronized (gLock)
    {
        if (loadLocked())
            return true;
        if (!warned)
        {
            import core.stdc.stdio : fprintf, stderr;

            warned = true;
            fprintf(stderr, "andaime: zlib (%s) not found: WebSockets are not compressed\n", zlibPkg.ptr);
        }
        return false;
    }
}

/// Why zlib cannot be used, or none when it loaded. Loads the library on the first call and prints nothing.
public Optional!string zlibLoadError() @trusted
{
    synchronized (gLock)
        return loadLocked() ? Optional!string.none : Optional!string(loadError);
}

/// True when libz is installed. Without it WebSockets are served uncompressed (permessage-deflate is not offered).
public bool zlibAvailable() => !zlibLoadError().has;

// Called with `gLock` held.
private bool loadLocked() @trusted nothrow
{
    if (loaded || failed)
        return loaded;
    void* lib;
    string detail;

    version (Windows)
        immutable string[] names = ["zlib1.dll\0", "zlib.dll\0"];
    else version (OSX)
        immutable string[] names = ["libz.1.dylib\0", "libz.dylib\0", "/opt/homebrew/lib/libz.dylib\0", "/usr/local/lib/libz.dylib\0"];
    else
        immutable string[] names = ["libz.so.1\0", "libz.so\0"];

    foreach (n; names)
    {
        lib = dlOpen(n.ptr);
        if (lib !is null)
            break;
        if (detail is null)
            detail = dlError();
    }
    if (lib is null)
        loadError = "andaime: zlib (" ~ zlibPkg ~ ") not found" ~ (detail is null ? "" : ": " ~ detail);
    else
    {
        string missing;
        static foreach (m; __traits(allMembers, Api))
        {
            {
                auto p = dlSym(lib, (m ~ "\0").ptr);
                if (p is null)
                    missing = m;
                else
                    __traits(getMember, z, m) = cast(typeof(__traits(getMember, z, m))) p;
            }
        }
        if (missing !is null)
            loadError = "andaime: missing symbol in zlib: " ~ missing;
        loaded = missing is null;
    }
    failed = !loaded;
    return loaded;
}

/// permessage-deflate state of one connection: a raw-deflate compressor (this side's window) and an inflater (15 bits
/// reads any window the peer chose). The zlib states are C memory, created on first use and freed by `release`.
final class ZlibDeflate : WsDeflate
{
    private ZStream def, inf; // inside a class object, which never moves: zlib keeps a pointer back to its z_stream
    private bool defReady, infReady, defFailed;
    private int bits;
    private bool noContext;

    this(int windowBits, bool noContextTakeover) nothrow
    {
        bits = windowBits;
        noContext = noContextTakeover;
    }

    // @trusted: zlib only reads `message` and writes into the `ByteBuffer`'s reserved space, both bounded by the lengths
    // passed with them; the streams live in this object.
    override bool compress(scope const(ubyte)[] message, ref ByteBuffer o) @trusted
    {
        // zlib turns an 8-bit window into 9 bits, which a peer that asked for 8 could not read: send uncompressed
        if (defFailed || bits < 9 || message.length > uint.max)
            return false;
        if (!defReady)
        {
            if (z.deflateInit2_(&def, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -bits, 8, Z_DEFAULT_STRATEGY, z.zlibVersion(),
                    cast(int) ZStream.sizeof) != Z_OK)
            {
                defFailed = true;
                return false;
            }
            defReady = true;
        }
        immutable start = o.length;
        def.next_in = message.ptr;
        def.avail_in = cast(uint) message.length;
        for (;;)
        {
            immutable room = message.length / 2 + 64;
            auto out_ = o.writable(room);
            def.next_out = cast(ubyte*) out_.ptr;
            def.avail_out = cast(uint) room;
            immutable r = z.deflate(&def, Z_SYNC_FLUSH);
            o.commit(room - def.avail_out);
            if (r != Z_OK && r != Z_BUF_ERROR)
                return fail(o, start);
            if (def.avail_out != 0) // everything is in and flushed
                break;
        }
        // a sync flush ends with an empty stored block, 00 00 FF FF, which the message leaves out (RFC 7692 §7.2.1)
        auto d = o.data;
        if (d.length < start + 4 || d[$ - 4 .. $] != "\x00\x00\xff\xff")
            return fail(o, start);
        o.trimEnd(4);
        if (noContext)
            z.deflateReset(&def);
        return true;
    }

    private bool fail(ref ByteBuffer o, size_t start) nothrow @trusted
    {
        o.trimEnd(o.length - start);
        z.deflateEnd(&def);
        defReady = false;
        defFailed = true;
        return false;
    }

    // @trusted: as `compress`
    override InflateResult decompress(scope const(ubyte)[] payload, ref ByteBuffer o, size_t limit) @trusted
    {
        if (payload.length > uint.max)
            return InflateResult.tooBig;
        if (!infReady)
        {
            if (z.inflateInit2_(&inf, -15, z.zlibVersion(), cast(int) ZStream.sizeof) != Z_OK)
                return InflateResult.error;
            infReady = true;
        }
        static immutable ubyte[4] tail = [0, 0, 0xff, 0xff];
        immutable start = o.length;
        auto r = inflatePart(payload, o, start, limit);
        if (r == InflateResult.ok)
            r = inflatePart(tail[], o, start, limit); // the flush marker the sender left out
        return r;
    }

    private InflateResult inflatePart(scope const(ubyte)[] part, ref ByteBuffer o, size_t start, size_t limit) @trusted
    {
        inf.next_in = part.ptr;
        inf.avail_in = cast(uint) part.length;
        for (;;)
        {
            immutable produced = o.length - start;
            if (produced > limit)
                return InflateResult.tooBig;
            immutable want = limit - produced + 1; // one more than allowed tells "too big" apart
            immutable room = want < (64 << 10) ? want : (64 << 10);
            auto out_ = o.writable(room);
            inf.next_out = cast(ubyte*) out_.ptr;
            inf.avail_out = cast(uint) room;
            immutable r = z.inflate(&inf, Z_SYNC_FLUSH);
            o.commit(room - inf.avail_out);
            if (r == Z_STREAM_END)
            {
                z.inflateReset(&inf); // the peer ended its stream (BFINAL): the next message starts a new one
                break;
            }
            if (r != Z_OK && r != Z_BUF_ERROR)
                return InflateResult.error;
            if (inf.avail_in == 0 && inf.avail_out != 0)
                break;
            if (r == Z_BUF_ERROR && inf.avail_out != 0)
                return InflateResult.error; // no progress with input left: corrupt
        }
        return o.length - start > limit ? InflateResult.tooBig : InflateResult.ok;
    }

    // @trusted: frees the C states this object created, once
    override void release() @trusted
    {
        if (defReady)
            z.deflateEnd(&def);
        if (infReady)
            z.inflateEnd(&inf);
        defReady = infReady = false;
    }
}

public:

/// A connection's permessage-deflate state, or null when zlib is not installed. The factory a server hands to its apps
/// (`Context.newDeflate`) and the WebSocket client uses.
WsDeflate zlibDeflate(int windowBits, bool noContextTakeover)
{
    if (!loadZlib())
        return null;
    return new ZlibDeflate(windowBits, noContextTakeover);
}

unittest
{
    if (!loadZlib())
        return;
    auto a = zlibDeflate(15, false);
    auto b = zlibDeflate(15, false);
    scope (exit)
    {
        a.release();
        b.release();
    }
    ByteBuffer c, d;
    foreach (round; 0 .. 3) // context takeover: later messages compress better, and must still inflate in order
    {
        c.clear();
        d.clear();
        auto msg = cast(const(ubyte)[]) "Hello, hello, hello, WebSocket compression! Hello, hello, hello again.";
        assert(a.compress(msg, c));
        assert(c.length < msg.length);
        assert(b.decompress(cast(const(ubyte)[]) c.data, d, 1 << 20) == InflateResult.ok);
        assert(d.data == cast(const(char)[]) msg);
    }
    // RFC 7692 §7.2.3.1: "Hello" compressed without context
    static immutable ubyte[7] hello = [0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00];
    auto e = zlibDeflate(15, true);
    scope (exit)
        e.release();
    d.clear();
    assert(e.decompress(hello[], d, 100) == InflateResult.ok && d.data == "Hello");
    // a bomb: a megabyte of zeros inflates past a small limit
    auto zeros = new ubyte[1 << 20];
    c.clear();
    assert(a.compress(zeros, c) && c.length < 4096);
    d.clear();
    auto f = zlibDeflate(15, false);
    scope (exit)
        f.release();
    assert(f.decompress(cast(const(ubyte)[]) c.data, d, 1000) == InflateResult.tooBig);
    d.clear();
    static immutable ubyte[3] junk = [0xff, 0xff, 0xff];
    auto g = zlibDeflate(15, false);
    scope (exit)
        g.release();
    assert(g.decompress(junk[], d, 1000) == InflateResult.error);
    // 8 bits: never compressed
    auto h = zlibDeflate(8, false);
    c.clear();
    assert(!h.compress(cast(const(ubyte)[]) "whatever whatever whatever", c) && c.length == 0);
}
