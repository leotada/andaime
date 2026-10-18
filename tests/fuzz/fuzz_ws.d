/// Mutation fuzzer for the WebSocket message layer (runs in check.sh, deterministic per seed): starts from valid client
/// frame sequences and breaks them at the byte and at the frame level.
/// Usage: fuzz_ws [iterations] [seed]
module fuzz_ws 2025;

import ws_invariants;
import andaime.http;
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

ubyte[] frame(ubyte opcode, const(ubyte)[] payload, bool fin = true, bool rsv1 = false)
{
    static immutable ubyte[4] key = [0xa1, 0xb2, 0xc3, 0xd4];
    ByteBuffer b;
    encodeFrame(b, opcode, fin, rsv1, payload, key[]);
    return cast(ubyte[]) b.data.dup;
}

ubyte[] t(string s) => cast(ubyte[]) s.dup;

ubyte[][] seeds()
{
    auto big = new ubyte[300];
    foreach (i, ref x; big)
        x = cast(ubyte)('a' + i % 26);
    return [
        // the first byte also picks the read size and whether "deflate" is on (odd)
        [cast(ubyte) 2] ~ frame(WsOpcode.text, t("hello")) ~ frame(WsOpcode.close, [0x03, 0xe8]),
        [cast(ubyte) 3] ~ frame(WsOpcode.text, t("zipped"), true, true) ~ frame(WsOpcode.binary, big, true, true),
        [cast(ubyte) 8] ~ frame(WsOpcode.text, t("frag"), false) ~ frame(WsOpcode.ping, t("p"))
            ~ frame(WsOpcode.continuation, t("ment"), false) ~ frame(WsOpcode.continuation, null),
        [cast(ubyte) 64] ~ frame(WsOpcode.binary, big) ~ frame(WsOpcode.pong, null) ~ frame(WsOpcode.close, null),
        [cast(ubyte) 1] ~ frame(WsOpcode.text, t("çã€\U0001F600")) ~ frame(WsOpcode.close, t("\x0f\xa0reason")),
        [cast(ubyte) 5] ~ frame(WsOpcode.text, big[0 .. 126]) ~ frame(WsOpcode.binary, new ubyte[5000]),
        [cast(ubyte) 9] ~ frame(WsOpcode.binary, t("\xff corrupt"), true, true),
    ];
}

ubyte[] mutate(ref Rng rng, const(ubyte)[] seed, ubyte[][] pool)
{
    auto b = seed.dup;
    foreach (_; 0 .. 1 + rng.below(4))
    {
        switch (rng.below(8))
        {
            case 0: // one byte
                if (b.length) b[rng.below(b.length)] = cast(ubyte) rng.below(256);
                break;
            case 1: // flip a bit (FIN, RSV, opcode, MASK, lengths)
                if (b.length) b[rng.below(b.length)] ^= cast(ubyte)(1 << rng.below(8));
                break;
            case 2: // delete a range
                if (b.length)
                {
                    auto i = rng.below(b.length);
                    auto n = rng.below(b.length - i + 1);
                    b = b[0 .. i] ~ b[i + n .. $];
                }
                break;
            case 3: // duplicate a range
                if (b.length)
                {
                    auto i = rng.below(b.length);
                    auto n = rng.below(b.length - i + 1);
                    b = b[0 .. i + n] ~ b[i .. i + n] ~ b[i + n .. $];
                }
                break;
            case 4: // splice another seed in
                auto o = pool[rng.below(pool.length)];
                auto i = rng.below(b.length + 1);
                b = b[0 .. i] ~ o[1 .. $] ~ b[i .. $];
                break;
            case 5: // a random frame header: odd lengths, unknown opcodes, unmasked
            {
                ubyte[] h = [cast(ubyte) rng.below(256), cast(ubyte) rng.below(256)];
                if ((h[1] & 0x7f) == 126) h ~= [cast(ubyte) rng.below(256), cast(ubyte) rng.below(256)];
                if ((h[1] & 0x7f) == 127) foreach (_k; 0 .. 8) h ~= cast(ubyte) rng.below(256);
                auto i = rng.below(b.length + 1);
                b = b[0 .. i] ~ h ~ b[i .. $];
                break;
            }
            case 6: // truncate
                if (b.length) b = b[0 .. rng.below(b.length)];
                break;
            default: // a length field at its edges
                static immutable ubyte[6] edges = [0, 1, 125, 126, 127, 255];
                if (b.length > 2) b[2] = edges[rng.below(6)];
                break;
        }
    }
    return b;
}

void main(string[] args)
{
    immutable iterations = args.length > 1 ? args[1].to!size_t : 100_000;
    auto rng = Rng(args.length > 2 ? args[2].to!ulong : 0x9e3779b97f4a7c15);
    auto pool = seeds();
    foreach (s; pool)
        checkWs(s);
    foreach (i; 0 .. iterations)
        checkWs(mutate(rng, pool[rng.below(pool.length)], pool));
    printf("WebSocket fuzz: %zu inputs, invariants held\n", iterations);
}
