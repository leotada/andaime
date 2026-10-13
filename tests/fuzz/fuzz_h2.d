/// Mutation fuzzer for the HTTP/2 session (runs in CI, deterministic per seed): starts from
/// valid frame sequences and breaks them at the byte and at the frame level.
/// Usage: fuzz_h2 [iterations] [seed]
module fuzz_h2;

import h2_invariants;
import vela.http;
import vela.http.hpack : encodeField, encodeInt;
import core.stdc.stdio : printf;
import std.conv : to;

struct Rng
{
    ulong s;
    ulong next()
    {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return s;
    }
    size_t below(size_t n) => n ? cast(size_t)(next() % n) : 0;
}

ubyte[] frame(ubyte type, ubyte flags, uint sid, const(ubyte)[] payload)
{
    ubyte[] f = [cast(ubyte)(payload.length >> 16), cast(ubyte)(payload.length >> 8), cast(ubyte) payload.length,
        type, flags, cast(ubyte)(sid >> 24), cast(ubyte)(sid >> 16), cast(ubyte)(sid >> 8), cast(ubyte) sid];
    return f ~ payload;
}

ubyte[] u32(uint v) => [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];

ubyte[] fields(string[2][] fs...)
{
    ByteBuffer b;
    foreach (f; fs)
        encodeField(b, f[0], f[1]);
    return cast(ubyte[]) b.data.dup;
}

ubyte[][] seeds()
{
    auto get = fields([":method", "GET"], [":scheme", "http"], [":path", "/a?b=c"], [":authority", "x"], ["cookie", "a=1"], ["cookie", "b=2"]);
    auto post = fields([":method", "POST"], [":scheme", "http"], [":path", "/p"], ["content-length", "5"]);
    // literal with incremental indexing + an index into the dynamic table + a size update
    ubyte[] indexed = [0x3f, 0xe1, 0x1f, 0x82, 0x86, 0x84, 0x40, 0x01, 'k', 0x01, 'v', 0xbe];
    // Huffman-coded :authority (RFC 7541 C.4.1)
    ubyte[] huff = [0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff];
    return [
        frame(1, 0x5, 1, get),
        frame(1, 0x4, 1, post) ~ frame(0, 0, 1, cast(ubyte[]) "ab") ~ frame(0, 1, 1, cast(ubyte[]) "cde"),
        frame(1, 0x1, 3, get[0 .. 5]) ~ frame(9, 0, 3, get[5 .. 9]) ~ frame(9, 4, 3, get[9 .. $]),
        frame(1, 0x5, 1, indexed) ~ frame(1, 0x5, 3, indexed[3 .. $]),
        frame(1, 0x5, 1, huff),
        frame(1, 0x2d, 5, cast(ubyte[]) [3, 0, 0, 0, 1, 16] ~ get ~ cast(ubyte[]) [0, 0, 0]), // padded + priority
        frame(4, 0, 0, [0, 4, 0, 0, 0, 10, 0, 5, 0, 0, 0x40, 0]) ~ frame(1, 5, 1, get) ~ frame(8, 0, 1, u32(100)),
        frame(6, 0, 0, cast(ubyte[]) "pingpong") ~ frame(8, 0, 0, u32(1000)) ~ frame(2, 0, 7, u32(1) ~ cast(ubyte[]) [9]),
        frame(1, 4, 1, post) ~ frame(3, 0, 1, u32(8)) ~ frame(0, 1, 1, cast(ubyte[]) "x"),
        frame(1, 4, 1, post) ~ frame(0, 0, 1, cast(ubyte[]) "12345") ~ frame(1, 5, 1, fields(["x-trailer", "1"])),
        frame(7, 0, 0, u32(0) ~ u32(0)) ~ frame(1, 5, 1, get),
        frame(0xee, 0xff, 0, cast(ubyte[]) "unknown frame") ~ frame(1, 5, 1, get),
    ];
}

ubyte[] mutate(ref Rng rng, const(ubyte)[] seed, ubyte[][] pool)
{
    auto b = seed.dup;
    foreach (_; 0 .. 1 + rng.below(4))
    {
        switch (rng.below(9))
        {
            case 0: // one byte
                if (b.length) b[rng.below(b.length)] = cast(ubyte) rng.below(256);
                break;
            case 1: // flip a bit (lengths, flags, stream ids)
                if (b.length) b[rng.below(b.length)] ^= cast(ubyte)(1 << rng.below(8));
                break;
            case 2: // delete a range
                if (b.length)
                {
                    auto i = rng.below(b.length);
                    auto n = 1 + rng.below(16);
                    if (i + n > b.length) n = b.length - i;
                    b = b[0 .. i] ~ b[i + n .. $];
                }
                break;
            case 3: // duplicate a range
                if (b.length)
                {
                    auto i = rng.below(b.length);
                    auto n = 1 + rng.below(64);
                    if (i + n > b.length) n = b.length - i;
                    b = b[0 .. i + n] ~ b[i .. $];
                }
                break;
            case 4: // splice another seed
            {
                auto o = pool[rng.below(pool.length)];
                auto i = rng.below(b.length + 1);
                b = b[0 .. i] ~ o ~ b[i .. $];
                break;
            }
            case 5: // an interesting frame header
            {
                ubyte[] h = frame(cast(ubyte) rng.below(12), cast(ubyte) rng.below(256),
                    cast(uint)(rng.below(2) ? rng.below(8) : rng.next()), null);
                auto len = rng.below(3) == 0 ? rng.below(1 << 24) : rng.below(40);
                h[0] = cast(ubyte)(len >> 16); h[1] = cast(ubyte)(len >> 8); h[2] = cast(ubyte) len;
                auto i = rng.below(b.length + 1);
                b = b[0 .. i] ~ h ~ b[i .. $];
                break;
            }
            case 6: // truncate
                if (b.length) b = b[0 .. rng.below(b.length)];
                break;
            case 7: // the same frames on another stream
                if (b.length >= 9)
                    b[8] = cast(ubyte)(rng.below(16));
                break;
            default: // random bytes
                foreach (k; 0 .. rng.below(32))
                    b ~= cast(ubyte) rng.below(256);
        }
    }
    return b;
}

void main(string[] args)
{
    immutable iterations = args.length > 1 ? args[1].to!size_t : 100_000;
    Rng rng = Rng(args.length > 2 ? args[2].to!ulong : 0x9e3779b97f4a7c15);
    auto pool = seeds();
    foreach (s; pool)
        checkH2(cast(ubyte[]) [0] ~ s); // every seed is valid and must pass as it is
    // inputs that once broke an invariant (found by tools/fuzz.sh) stay fixed
    import std.file : dirEntries, SpanMode, read, exists;

    size_t replayed;
    if (exists("tests/fuzz/h2_regressions"))
        foreach (f; dirEntries("tests/fuzz/h2_regressions", SpanMode.shallow))
        {
            checkH2(cast(const(ubyte)[]) read(f.name));
            replayed++;
        }
    printf("ok  HTTP/2 fuzz regressions: %zu inputs replayed\n", replayed);
    foreach (i; 0 .. iterations)
        checkH2(mutate(rng, pool[rng.below(pool.length)], pool));
    printf("ok  HTTP/2 mutation fuzz: %zu inputs, invariants held\n", iterations);
}
