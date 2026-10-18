/// HPACK (RFC 7541): header compression for HTTP/2. Pure: no I/O, no GC on the hot path.
///
/// - `HpackDecoder` keeps the peer's dynamic table (bytes outside the GC heap) and decodes a
///   complete header block, handing each field to a sink. Huffman strings are decoded with the
///   canonical code of Appendix B.
/// - The encoder is stateless on purpose: responses use the static table and literals
///   "without indexing", never the dynamic table. Each stream's fiber can then encode its own
///   response head without coordinating with the connection, at the cost of a few bytes per
///   header. Strings are sent raw (no Huffman): encoding is a copy.
module andaime.http.hpack 2025;

@safe:

import andaime.http.types : HeaderField;
import andaime.http.buffer : ByteBuffer;

enum HpackError : ubyte
{
    none,
    truncated,       /// the block ends in the middle of a representation
    badIndex,        /// index 0 or beyond the tables
    badHuffman,      /// invalid code, EOS inside the string or bad padding
    integerOverflow, /// integer larger than 2^32
    tableSizeUpdate, /// size update above the limit, or not at the start of the block
    tooLong,         /// a single string above `maxStringBytes`
}

/// Receives each decoded field. The slices are only valid during the call (they point into the
/// decoder's scratch space); copy what you keep. `sensitive` = "never indexed" representation.
alias HpackSink = void delegate(scope const(char)[] name, scope const(char)[] value, bool sensitive) nothrow @safe;

/// Decoder with the dynamic table of one connection (one direction).
struct HpackDecoder
{
    @disable this(this);

    private static struct Entry
    {
        uint off;  /// offset of the name in `bytes`; the value follows it
        uint nameLen;
        uint valueLen;
    }

    private char[] bytes;    /// live region [head, tail); capacity 2 * maxAllowed (malloc)
    private size_t head, tail;
    private Entry[] ring;    /// circular; newest at (first + count - 1)
    private size_t first, count;
    private size_t used;     /// RFC size: sum(name + value + 32)
    private size_t maxSize;  /// current limit (changed by size updates)
    private size_t maxAllowed = 4096; /// SETTINGS_HEADER_TABLE_SIZE we announced
    private ByteBuffer nameScratch, valueScratch;

    /// Longest single string accepted after Huffman decoding.
    size_t maxStringBytes = 64 << 10;

    ~this() @trusted nothrow @nogc
    {
        import core.stdc.stdlib : free;

        free(bytes.ptr);
        free(ring.ptr);
    }

    /// Sets the table limit we announced. Call before the first `decode`.
    void setMaxAllowed(size_t n) nothrow @nogc
    {
        maxAllowed = n;
        maxSize = n;
    }

    /// Current size of the dynamic table (for tests).
    size_t tableSize() const pure nothrow @nogc => used;

    /// Frees the table and scratch space now (instead of when the owner is collected).
    void releaseMemory() nothrow @nogc @trusted
    {
        import core.stdc.stdlib : free;

        free(bytes.ptr);
        free(ring.ptr);
        bytes = null;
        ring = null;
        nameScratch.shrinkTo(0);
        valueScratch.shrinkTo(0);
        reset();
    }

    /// Back to the initial state, keeping the memory (connection reuse).
    void reset() nothrow @nogc
    {
        head = tail = first = count = used = 0;
        maxSize = maxAllowed;
    }

    private void ensureStorage() nothrow @nogc @trusted
    {
        import core.stdc.stdlib : malloc;
        import core.exception : onOutOfMemoryError;

        if (bytes.length)
            return;
        immutable cap = maxAllowed * 2 < 64 ? 64 : maxAllowed * 2;
        immutable entries = maxAllowed / 32 + 1;
        auto b = cast(char*) malloc(cap);
        auto r = cast(Entry*) malloc(entries * Entry.sizeof);
        if (b is null || r is null)
            onOutOfMemoryError();
        bytes = b[0 .. cap];
        ring = r[0 .. entries];
    }

    private void evictOldest() nothrow @nogc
    {
        auto e = ring[first];
        used -= e.nameLen + e.valueLen + 32;
        first = (first + 1) % ring.length;
        count--;
        head = count ? ring[first].off : tail;
        if (count == 0)
            head = tail = 0;
    }

    private void evictTo(size_t limit) nothrow @nogc
    {
        while (count && used > limit)
            evictOldest();
    }

    private void insert(scope const(char)[] name, scope const(char)[] value) nothrow @nogc @trusted
    {
        immutable size = name.length + value.length + 32;
        if (size > maxSize)
        {
            evictTo(0); // RFC 7541 §4.4: an entry larger than the table empties it
            return;
        }
        ensureStorage();
        evictTo(maxSize - size);
        immutable n = name.length + value.length;
        if (tail + n > bytes.length)
        {
            // the live region is contiguous (append at the tail, evict at the head): slide it down
            import core.stdc.string : memmove;

            immutable live = tail - head;
            if (live)
                memmove(bytes.ptr, bytes.ptr + head, live);
            foreach (i; 0 .. count)
                ring[(first + i) % ring.length].off -= cast(uint) head;
            head = 0;
            tail = live;
        }
        bytes[tail .. tail + name.length] = name[];
        bytes[tail + name.length .. tail + n] = value[];
        immutable slot = (first + count) % ring.length;
        ring[slot] = Entry(cast(uint) tail, cast(uint) name.length, cast(uint) value.length);
        if (count == 0)
            head = tail;
        tail += n;
        count++;
        used += size;
    }

    /// Field at HPACK index `i` (1-based: static table, then dynamic, newest first).
    private bool lookup(size_t i, out const(char)[] name, out const(char)[] value) const nothrow @nogc
    {
        if (i == 0)
            return false;
        if (i <= staticTable.length)
        {
            name = staticTable[i - 1].name;
            value = staticTable[i - 1].value;
            return true;
        }
        immutable d = i - staticTable.length - 1; // 0 = newest
        if (d >= count)
            return false;
        auto e = ring[(first + count - 1 - d) % ring.length];
        name = bytes[e.off .. e.off + e.nameLen];
        value = bytes[e.off + e.nameLen .. e.off + e.nameLen + e.valueLen];
        return true;
    }

    /// Decodes a complete header block (HEADERS + CONTINUATIONs already joined).
    /// On error the connection must be closed with COMPRESSION_ERROR: the table is out of sync.
    HpackError decode(scope const(ubyte)[] block, scope HpackSink sink) nothrow
    {
        size_t p = 0;
        bool fieldSeen = false;
        while (p < block.length)
        {
            immutable b = block[p];
            if (b & 0x80) // indexed field
            {
                size_t idx;
                if (auto e = decodeInt(block, p, 7, idx))
                    return e;
                const(char)[] n, v;
                if (!lookup(idx, n, v))
                    return HpackError.badIndex;
                sink(n, v, false);
                fieldSeen = true;
            }
            else if ((b & 0xe0) == 0x20) // dynamic table size update
            {
                size_t size;
                if (auto e = decodeInt(block, p, 5, size))
                    return e;
                if (fieldSeen || size > maxAllowed)
                    return HpackError.tableSizeUpdate;
                maxSize = size;
                evictTo(size);
            }
            else
            {
                // literal: 01 = incremental indexing (6-bit index), 0000 = without indexing,
                // 0001 = never indexed (4-bit index)
                immutable indexing = (b & 0xc0) == 0x40;
                immutable sensitive = (b & 0xf0) == 0x10;
                size_t idx;
                if (auto e = decodeInt(block, p, indexing ? 6 : 4, idx))
                    return e;
                const(char)[] name;
                if (idx)
                {
                    const(char)[] n, unused;
                    if (!lookup(idx, n, unused))
                        return HpackError.badIndex;
                    nameScratch.clear();
                    nameScratch.put(n); // the entry may be evicted by this very insertion
                    name = nameScratch.data;
                }
                else
                {
                    if (auto e = decodeString(block, p, nameScratch))
                        return e;
                    name = nameScratch.data;
                }
                if (auto e = decodeString(block, p, valueScratch))
                    return e;
                sink(name, valueScratch.data, sensitive);
                if (indexing)
                    insert(name, valueScratch.data);
                fieldSeen = true;
            }
        }
        return HpackError.none;
    }

    private HpackError decodeString(scope const(ubyte)[] block, ref size_t p, ref ByteBuffer o) nothrow
    {
        if (p >= block.length)
            return HpackError.truncated;
        immutable huffman = (block[p] & 0x80) != 0;
        size_t len;
        if (auto e = decodeInt(block, p, 7, len))
            return e;
        if (len > block.length - p)
            return HpackError.truncated;
        auto raw = block[p .. p + len];
        p += len;
        o.clear();
        if (!huffman)
        {
            if (len > maxStringBytes)
                return HpackError.tooLong;
            o.put(cast(const(char)[]) raw);
            return HpackError.none;
        }
        return huffmanDecode(raw, o, maxStringBytes);
    }
}

/// HPACK integer with an N-bit prefix (§5.1), starting at `block[p]`. Advances `p`.
HpackError decodeInt(scope const(ubyte)[] block, ref size_t p, uint prefixBits, out size_t value) pure nothrow @nogc
{
    if (p >= block.length)
        return HpackError.truncated;
    immutable uint mask = (1u << prefixBits) - 1;
    ulong v = block[p++] & mask;
    if (v < mask)
    {
        value = cast(size_t) v;
        return HpackError.none;
    }
    uint shift = 0;
    for (;;)
    {
        if (p >= block.length)
            return HpackError.truncated;
        immutable b = block[p++];
        v += cast(ulong)(b & 0x7f) << shift;
        if (v > uint.max)
            return HpackError.integerOverflow;
        if (!(b & 0x80))
            break;
        shift += 7;
        if (shift > 28)
            return HpackError.integerOverflow;
    }
    value = cast(size_t) v;
    return HpackError.none;
}

/// Writes an HPACK integer: `flags` go in the bits above the N-bit prefix.
void encodeInt(ref ByteBuffer o, uint prefixBits, ubyte flags, size_t value) nothrow @nogc
{
    immutable size_t mask = (1u << prefixBits) - 1;
    if (value < mask)
    {
        o.put(cast(char)(flags | value));
        return;
    }
    o.put(cast(char)(flags | mask));
    value -= mask;
    while (value >= 0x80)
    {
        o.put(cast(char)((value & 0x7f) | 0x80));
        value >>= 7;
    }
    o.put(cast(char) value);
}

/// Decodes a Huffman string (canonical code: walks the code bit by bit by length).
HpackError huffmanDecode(scope const(ubyte)[] src, ref ByteBuffer o, size_t maxOut = size_t.max) nothrow @nogc
{
    uint code = 0;
    uint len = 0;
    foreach (b; src)
    {
        foreach_reverse (bit; 0 .. 8)
        {
            code = (code << 1) | ((b >> bit) & 1);
            len++;
            immutable k = code - huffFirst[len]; // wraps when code < first: then not a match
            if (k < huffCount[len])
            {
                immutable sym = huffSymbols[huffOffset[len] + k];
                if (sym == 256)
                    return HpackError.badHuffman; // EOS inside a string (§5.2)
                if (o.length >= maxOut)
                    return HpackError.tooLong;
                o.put(cast(char) sym);
                code = 0;
                len = 0;
            }
            else if (len == 30)
                return HpackError.badHuffman;
        }
    }
    // padding: at most 7 bits, all ones (most significant bits of EOS)
    if (len > 7 || code != (1u << len) - 1)
        return HpackError.badHuffman;
    return HpackError.none;
}

/// Index (1-based) of the first static entry named `lowerName`, or 0.
size_t staticNameIndex(scope const(char)[] lowerName) pure nothrow @nogc
{
    foreach (i, ref f; staticTable)
        if (f.name == lowerName)
            return i + 1;
    return 0;
}

/// `:status` as an indexed field when the static table has it, otherwise a literal.
void encodeStatus(ref ByteBuffer o, int status) nothrow @nogc
{
    switch (status)
    {
        case 200: o.put(cast(char) 0x88); return;
        case 204: o.put(cast(char) 0x89); return;
        case 206: o.put(cast(char) 0x8a); return;
        case 304: o.put(cast(char) 0x8b); return;
        case 400: o.put(cast(char) 0x8c); return;
        case 404: o.put(cast(char) 0x8d); return;
        case 500: o.put(cast(char) 0x8e); return;
        default:
            if (status < 100 || status > 999)
                status = 500;
            o.put(cast(char) 0x08); // literal without indexing, name = static 8 (:status)
            o.put(cast(char) 3);
            o.put(cast(char)('0' + status / 100));
            o.put(cast(char)('0' + status / 10 % 10));
            o.put(cast(char)('0' + status % 10));
    }
}

/// Literal field without indexing. The name is lowercased while it is written (HTTP/2 requires it).
void encodeField(ref ByteBuffer o, scope const(char)[] name, scope const(char)[] value, bool sensitive = false) nothrow @nogc
{
    char[32] low = void;
    size_t idx = 0;
    if (name.length <= low.length)
    {
        foreach (i, c; name)
            low[i] = c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
        idx = staticNameIndex(low[0 .. name.length]);
    }
    immutable ubyte flag = sensitive ? 0x10 : 0x00;
    if (idx)
        encodeInt(o, 4, flag, idx);
    else
    {
        o.put(cast(char) flag);
        encodeInt(o, 7, 0, name.length);
        foreach (c; name)
            o.put(c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c);
    }
    encodeInt(o, 7, 0, value.length);
    o.put(value);
}

// Generated from RFC 7541 Appendix B (canonical code): symbols ordered by (length, symbol).
private static immutable ushort[257] huffSymbols = [
    48, 49, 50, 97, 99, 101, 105, 111, 115, 116, 32, 37, 45, 46, 47, 51,
    52, 53, 54, 55, 56, 57, 61, 65, 95, 98, 100, 102, 103, 104, 108, 109,
    110, 112, 114, 117, 58, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76,
    77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 89, 106, 107, 113, 118,
    119, 120, 121, 122, 38, 42, 44, 59, 88, 90, 33, 34, 40, 41, 63, 39,
    43, 124, 35, 62, 0, 36, 64, 91, 93, 126, 94, 125, 60, 96, 123, 92,
    195, 208, 128, 130, 131, 162, 184, 194, 224, 226, 153, 161, 167, 172, 176, 177,
    179, 209, 216, 217, 227, 229, 230, 129, 132, 133, 134, 136, 146, 154, 156, 160,
    163, 164, 169, 170, 173, 178, 181, 185, 186, 187, 189, 190, 196, 198, 228, 232,
    233, 1, 135, 137, 138, 139, 140, 141, 143, 147, 149, 150, 151, 152, 155, 157,
    158, 165, 166, 168, 174, 175, 180, 182, 183, 188, 191, 197, 231, 239, 9, 142,
    144, 145, 148, 159, 171, 206, 215, 225, 236, 237, 199, 207, 234, 235, 192, 193,
    200, 201, 202, 205, 210, 213, 218, 219, 238, 240, 242, 243, 255, 203, 204, 211,
    212, 214, 221, 222, 223, 241, 244, 245, 246, 247, 248, 250, 251, 252, 253, 254,
    2, 3, 4, 5, 6, 7, 8, 11, 12, 14, 15, 16, 17, 18, 19, 20,
    21, 23, 24, 25, 26, 27, 28, 29, 30, 31, 127, 220, 249, 10, 13, 22,
    256,
];
/// First code, number of codes and first index in huffSymbols for each length 0..30.
private static immutable uint[31] huffFirst = [0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x14, 0x5c, 0xf8, 0x0, 0x3f8, 0x7fa, 0xffa, 0x1ff8, 0x3ffc, 0x7ffc, 0x0, 0x0, 0x0, 0x7fff0, 0xfffe6, 0x1fffdc, 0x3fffd2, 0x7fffd8, 0xffffea, 0x1ffffec, 0x3ffffe0, 0x7ffffde, 0xfffffe2, 0x0, 0x3ffffffc];
private static immutable ushort[31] huffCount = [0, 0, 0, 0, 0, 10, 26, 32, 6, 0, 5, 3, 2, 6, 2, 3, 0, 0, 0, 3, 8, 13, 26, 29, 12, 4, 15, 19, 29, 0, 4];
private static immutable ushort[31] huffOffset = [0, 0, 0, 0, 0, 0, 10, 36, 68, 0, 74, 79, 82, 84, 90, 92, 0, 0, 0, 95, 98, 106, 119, 145, 174, 186, 190, 205, 224, 0, 253];

/// RFC 7541 Appendix A (index 1..61).
private static immutable HeaderField[61] staticTable = [
    HeaderField(":authority", ""),
    HeaderField(":method", "GET"),
    HeaderField(":method", "POST"),
    HeaderField(":path", "/"),
    HeaderField(":path", "/index.html"),
    HeaderField(":scheme", "http"),
    HeaderField(":scheme", "https"),
    HeaderField(":status", "200"),
    HeaderField(":status", "204"),
    HeaderField(":status", "206"),
    HeaderField(":status", "304"),
    HeaderField(":status", "400"),
    HeaderField(":status", "404"),
    HeaderField(":status", "500"),
    HeaderField("accept-charset", ""),
    HeaderField("accept-encoding", "gzip, deflate"),
    HeaderField("accept-language", ""),
    HeaderField("accept-ranges", ""),
    HeaderField("accept", ""),
    HeaderField("access-control-allow-origin", ""),
    HeaderField("age", ""),
    HeaderField("allow", ""),
    HeaderField("authorization", ""),
    HeaderField("cache-control", ""),
    HeaderField("content-disposition", ""),
    HeaderField("content-encoding", ""),
    HeaderField("content-language", ""),
    HeaderField("content-length", ""),
    HeaderField("content-location", ""),
    HeaderField("content-range", ""),
    HeaderField("content-type", ""),
    HeaderField("cookie", ""),
    HeaderField("date", ""),
    HeaderField("etag", ""),
    HeaderField("expect", ""),
    HeaderField("expires", ""),
    HeaderField("from", ""),
    HeaderField("host", ""),
    HeaderField("if-match", ""),
    HeaderField("if-modified-since", ""),
    HeaderField("if-none-match", ""),
    HeaderField("if-range", ""),
    HeaderField("if-unmodified-since", ""),
    HeaderField("last-modified", ""),
    HeaderField("link", ""),
    HeaderField("location", ""),
    HeaderField("max-forwards", ""),
    HeaderField("proxy-authenticate", ""),
    HeaderField("proxy-authorization", ""),
    HeaderField("range", ""),
    HeaderField("referer", ""),
    HeaderField("refresh", ""),
    HeaderField("retry-after", ""),
    HeaderField("server", ""),
    HeaderField("set-cookie", ""),
    HeaderField("strict-transport-security", ""),
    HeaderField("transfer-encoding", ""),
    HeaderField("user-agent", ""),
    HeaderField("vary", ""),
    HeaderField("via", ""),
    HeaderField("www-authenticate", ""),
];

version (unittest) private static immutable uint[257] huffCodeForTest = [
    0x1ff8, 0x7fffd8, 0xfffffe2, 0xfffffe3, 0xfffffe4, 0xfffffe5, 0xfffffe6, 0xfffffe7,
    0xfffffe8, 0xffffea, 0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd, 0xfffffeb, 0xfffffec,
    0xfffffed, 0xfffffee, 0xfffffef, 0xffffff0, 0xffffff1, 0xffffff2, 0x3ffffffe, 0xffffff3,
    0xffffff4, 0xffffff5, 0xffffff6, 0xffffff7, 0xffffff8, 0xffffff9, 0xffffffa, 0xffffffb,
    0x14, 0x3f8, 0x3f9, 0xffa, 0x1ff9, 0x15, 0xf8, 0x7fa,
    0x3fa, 0x3fb, 0xf9, 0x7fb, 0xfa, 0x16, 0x17, 0x18,
    0x0, 0x1, 0x2, 0x19, 0x1a, 0x1b, 0x1c, 0x1d,
    0x1e, 0x1f, 0x5c, 0xfb, 0x7ffc, 0x20, 0xffb, 0x3fc,
    0x1ffa, 0x21, 0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62,
    0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a,
    0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72,
    0xfc, 0x73, 0xfd, 0x1ffb, 0x7fff0, 0x1ffc, 0x3ffc, 0x22,
    0x7ffd, 0x3, 0x23, 0x4, 0x24, 0x5, 0x25, 0x26,
    0x27, 0x6, 0x74, 0x75, 0x28, 0x29, 0x2a, 0x7,
    0x2b, 0x76, 0x2c, 0x8, 0x9, 0x2d, 0x77, 0x78,
    0x79, 0x7a, 0x7b, 0x7ffe, 0x7fc, 0x3ffd, 0x1ffd, 0xffffffc,
    0xfffe6, 0x3fffd2, 0xfffe7, 0xfffe8, 0x3fffd3, 0x3fffd4, 0x3fffd5, 0x7fffd9,
    0x3fffd6, 0x7fffda, 0x7fffdb, 0x7fffdc, 0x7fffdd, 0x7fffde, 0xffffeb, 0x7fffdf,
    0xffffec, 0xffffed, 0x3fffd7, 0x7fffe0, 0xffffee, 0x7fffe1, 0x7fffe2, 0x7fffe3,
    0x7fffe4, 0x1fffdc, 0x3fffd8, 0x7fffe5, 0x3fffd9, 0x7fffe6, 0x7fffe7, 0xffffef,
    0x3fffda, 0x1fffdd, 0xfffe9, 0x3fffdb, 0x3fffdc, 0x7fffe8, 0x7fffe9, 0x1fffde,
    0x7fffea, 0x3fffdd, 0x3fffde, 0xfffff0, 0x1fffdf, 0x3fffdf, 0x7fffeb, 0x7fffec,
    0x1fffe0, 0x1fffe1, 0x3fffe0, 0x1fffe2, 0x7fffed, 0x3fffe1, 0x7fffee, 0x7fffef,
    0xfffea, 0x3fffe2, 0x3fffe3, 0x3fffe4, 0x7ffff0, 0x3fffe5, 0x3fffe6, 0x7ffff1,
    0x3ffffe0, 0x3ffffe1, 0xfffeb, 0x7fff1, 0x3fffe7, 0x7ffff2, 0x3fffe8, 0x1ffffec,
    0x3ffffe2, 0x3ffffe3, 0x3ffffe4, 0x7ffffde, 0x7ffffdf, 0x3ffffe5, 0xfffff1, 0x1ffffed,
    0x7fff2, 0x1fffe3, 0x3ffffe6, 0x7ffffe0, 0x7ffffe1, 0x3ffffe7, 0x7ffffe2, 0xfffff2,
    0x1fffe4, 0x1fffe5, 0x3ffffe8, 0x3ffffe9, 0xffffffd, 0x7ffffe3, 0x7ffffe4, 0x7ffffe5,
    0xfffec, 0xfffff3, 0xfffed, 0x1fffe6, 0x3fffe9, 0x1fffe7, 0x1fffe8, 0x7ffff3,
    0x3fffea, 0x3fffeb, 0x1ffffee, 0x1ffffef, 0xfffff4, 0xfffff5, 0x3ffffea, 0x7ffff4,
    0x3ffffeb, 0x7ffffe6, 0x3ffffec, 0x3ffffed, 0x7ffffe7, 0x7ffffe8, 0x7ffffe9, 0x7ffffea,
    0x7ffffeb, 0xffffffe, 0x7ffffec, 0x7ffffed, 0x7ffffee, 0x7ffffef, 0x7fffff0, 0x3ffffee,
    0x3fffffff,
];
version (unittest) private static immutable ubyte[257] huffLenForTest = [
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28,
    28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    6, 10, 10, 12, 13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6,
    5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8, 15, 6, 12, 10,
    13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14, 6,
    15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5,
    6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7, 15, 11, 14, 13, 28,
    20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
    24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
    22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23,
    21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
    26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25,
    19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27,
    20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
    26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26,
    30,
];

// ----------------------------------------------------------------------------- tests

version (unittest)
{
    private ubyte[] hex(string s) pure
    {
        ubyte[] r;
        ubyte acc;
        bool half;
        foreach (c; s)
        {
            int d;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            else continue;
            if (half) { r ~= cast(ubyte)(acc << 4 | d); half = false; }
            else { acc = cast(ubyte) d; half = true; }
        }
        return r;
    }

    private string decodeAll(ref HpackDecoder d, string hexBlock, out HpackError err)
    {
        string got;
        err = d.decode(hex(hexBlock), (scope n, scope v, bool s) { got ~= n ~ ": " ~ v ~ "\n"; });
        return got;
    }

    private ubyte[] huffEncode(string s) pure
    {
        ubyte[] r;
        ulong acc;
        uint bits;
        foreach (char c; s)
        {
            acc = (acc << huffLenForTest[c]) | huffCodeForTest[c];
            bits += huffLenForTest[c];
            while (bits >= 8)
            {
                bits -= 8;
                r ~= cast(ubyte)(acc >> bits);
            }
        }
        if (bits)
            r ~= cast(ubyte)((acc << (8 - bits)) | ((1 << (8 - bits)) - 1));
        return r;
    }
}

unittest // integers (RFC 7541 C.1)
{
    ByteBuffer o;
    encodeInt(o, 5, 0, 10);
    encodeInt(o, 5, 0, 1337);
    encodeInt(o, 8, 0, 42);
    assert(cast(const(ubyte)[]) o.data == [0x0a, 0x1f, 0x9a, 0x0a, 0x2a]);
    size_t p, v;
    auto b = cast(const(ubyte)[]) o.data;
    assert(decodeInt(b, p, 5, v) == HpackError.none && v == 10);
    assert(decodeInt(b, p, 5, v) == HpackError.none && v == 1337);
    assert(decodeInt(b, p, 8, v) == HpackError.none && v == 42 && p == b.length);
    ubyte[7] huge = [0x1f, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f];
    p = 0;
    assert(decodeInt(huge[], p, 5, v) == HpackError.integerOverflow);
    p = 0;
    assert(decodeInt(huge[0 .. 3], p, 5, v) == HpackError.truncated);
}

unittest // C.3: requests without Huffman, sharing one dynamic table
{
    HpackDecoder d;
    d.setMaxAllowed(4096);
    HpackError e;
    auto r1 = decodeAll(d, "8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d", e);
    assert(e == HpackError.none);
    assert(r1 == ":method: GET\n:scheme: http\n:path: /\n:authority: www.example.com\n", r1);
    assert(d.tableSize == 57);
    auto r2 = decodeAll(d, "8286 84be 5808 6e6f 2d63 6163 6865", e);
    assert(r2 == ":method: GET\n:scheme: http\n:path: /\n:authority: www.example.com\ncache-control: no-cache\n", r2);
    assert(d.tableSize == 110);
    auto r3 = decodeAll(d, "8287 85bf 400a 6375 7374 6f6d 2d6b 6579 0c63 7573 746f 6d2d 7661 6c75 65", e);
    assert(r3 == ":method: GET\n:scheme: https\n:path: /index.html\n:authority: www.example.com\ncustom-key: custom-value\n", r3);
    assert(d.tableSize == 164);
}

unittest // C.4: the same requests with Huffman
{
    HpackDecoder d;
    d.setMaxAllowed(4096);
    HpackError e;
    auto r1 = decodeAll(d, "8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff", e);
    assert(e == HpackError.none && r1 == ":method: GET\n:scheme: http\n:path: /\n:authority: www.example.com\n", r1);
    auto r2 = decodeAll(d, "8286 84be 5886 a8eb 1064 9cbf", e);
    assert(r2 == ":method: GET\n:scheme: http\n:path: /\n:authority: www.example.com\ncache-control: no-cache\n", r2);
    auto r3 = decodeAll(d, "8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf", e);
    assert(r3 == ":method: GET\n:scheme: https\n:path: /index.html\n:authority: www.example.com\ncustom-key: custom-value\n", r3);
}

unittest // C.5: eviction with a 256-byte table
{
    HpackDecoder d;
    d.setMaxAllowed(256);
    HpackError e;
    decodeAll(d, "4803 3330 3258 0770 7269 7661 7465 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133 2032 303a 3133 3a32 3120 474d 546e 1768 7474 7073 3a2f 2f77 7777 2e65 7861 6d70 6c65 2e63 6f6d", e);
    assert(e == HpackError.none && d.tableSize == 222);
    auto r2 = decodeAll(d, "4803 3330 37c1 c0bf", e);
    assert(e == HpackError.none && d.tableSize == 222, r2);
    assert(r2 == ":status: 307\ncache-control: private\ndate: Mon, 21 Oct 2013 20:13:21 GMT\nlocation: https://www.example.com\n", r2);
    auto r3 = decodeAll(d, "88c1 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133 2032 303a 3133 3a32 3220 474d 54c0 5a04 677a 6970 7738 666f 6f3d 4153 444a 4b48 514b 425a 584f 5157 454f 5049 5541 5851 5745 4f49 553b 206d 6178 2d61 6765 3d33 3630 303b 2076 6572 7369 6f6e 3d31", e);
    assert(e == HpackError.none && d.tableSize == 215, r3);
    assert(r3 == ":status: 200\ncache-control: private\ndate: Mon, 21 Oct 2013 20:13:22 GMT\nlocation: https://www.example.com\n"
        ~ "content-encoding: gzip\nset-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1\n", r3);
}

unittest // errors
{
    HpackDecoder d;
    d.setMaxAllowed(4096);
    HpackError e;
    decodeAll(d, "80", e);
    assert(e == HpackError.badIndex);
    decodeAll(d, "be", e); // dynamic index 62 on an empty table
    assert(e == HpackError.badIndex);
    decodeAll(d, "82 3fe11f", e); // size update after a field
    assert(e == HpackError.tableSizeUpdate);
    decodeAll(d, "3fe21f", e); // size update to 4097 > 4096
    assert(e == HpackError.tableSizeUpdate);
    decodeAll(d, "3fe11f 82", e); // size update to 4096 at the start: fine
    assert(e == HpackError.none);
    decodeAll(d, "0003 6162", e); // literal truncated
    assert(e == HpackError.truncated);
    decodeAll(d, "0081 ff 00", e); // Huffman: 8 bits of padding
    assert(e == HpackError.badHuffman);
    decodeAll(d, "0084 ffff ffff 00", e); // Huffman: EOS (30 ones) inside the string
    assert(e == HpackError.badHuffman);
    decodeAll(d, "0081 00 00", e); // Huffman: padding with zeros
    assert(e == HpackError.badHuffman);
}

unittest // Huffman round trip over every byte value and the size limit
{
    char[256] all;
    foreach (i; 0 .. 256)
        all[i] = cast(char) i;
    auto enc = huffEncode(all.idup);
    ByteBuffer o;
    assert(huffmanDecode(enc, o) == HpackError.none && o.data == all[]);
    o.clear();
    assert(huffmanDecode(huffEncode("abcdef"), o, 3) == HpackError.tooLong);
}

unittest // the encoder's output decodes back, names lowercased
{
    ByteBuffer o;
    encodeStatus(o, 200);
    encodeStatus(o, 422);
    encodeField(o, "Content-Type", "application/json");
    encodeField(o, "X-Request-Id", "abc");
    encodeField(o, "Set-Cookie", "a=b", true);
    HpackDecoder d;
    d.setMaxAllowed(4096);
    string got;
    assert(d.decode(cast(const(ubyte)[]) o.data, (scope n, scope v, bool s) {
        got ~= n ~ "=" ~ v ~ (s ? "!" : "") ~ ";";
    }) == HpackError.none);
    assert(got == ":status=200;:status=422;content-type=application/json;x-request-id=abc;set-cookie=a=b!;", got);
    assert(d.tableSize == 0); // nothing indexed
}

unittest // the dynamic table survives many insertions (compaction and wrap-around)
{
    HpackDecoder d;
    d.setMaxAllowed(128);
    ByteBuffer blk;
    foreach (i; 0 .. 200)
    {
        blk.clear();
        blk.put(cast(char) 0x40);
        encodeInt(blk, 7, 0, 4);
        blk.put("k");
        blk.put(cast(char)('a' + i % 26));
        blk.put(cast(char)('a' + i / 26 % 26));
        blk.put("x");
        encodeInt(blk, 7, 0, 10 + i % 7);
        foreach (j; 0 .. 10 + i % 7)
            blk.put(cast(char)('0' + (i + j) % 10));
        blk.put(cast(char) 0xbe); // index 62 = the field just inserted
        string got;
        assert(d.decode(cast(const(ubyte)[]) blk.data, (scope n, scope v, bool s) { got ~= n ~ "=" ~ v ~ ";"; }) == HpackError.none);
        auto semi = got.length / 2;
        assert(got[0 .. semi] == got[semi .. $], got);
        assert(d.tableSize <= 128);
    }
}
