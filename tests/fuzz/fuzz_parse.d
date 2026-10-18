/// Mutation fuzzer for the parser (runs in CI, deterministic per seed).
/// Usage: fuzz_parse [iterations] [seed]
module fuzz_parse;

import invariants;
import andaime.http.parser;
import core.stdc.stdio : printf;
import std.file : dirEntries, SpanMode, read;
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

static immutable string[] tokens = [
    "\r\n", "\r\n\r\n", "\n", "\r", ": ", ":", " ", "\t", "\0", "HTTP/1.1", "HTTP/1.0", "HTTP/2.0",
    "Content-Length", "Transfer-Encoding", "chunked", "Expect", "100-continue", "Connection", "close",
    "Host", "GET ", "POST ", "/", "?", "%00", "..", "0", "99999999999999999999", "-1", "+1", "0x10",
];

char[] mutate(ref Rng rng, const(char)[] seed, const(char)[][] pool)
{
    auto b = seed.dup;
    foreach (_; 0 .. 1 + rng.below(4))
    {
        switch (rng.below(8))
        {
            case 0: // replaces one byte
                if (b.length) b[rng.below(b.length)] = cast(char) rng.below(256);
                break;
            case 1: // deletes a range
                if (b.length)
                {
                    auto i = rng.below(b.length);
                    auto n = 1 + rng.below(8);
                    if (i + n > b.length) n = b.length - i;
                    b = b[0 .. i] ~ b[i + n .. $];
                }
                break;
            case 2: // inserts an interesting token
            {
                auto t = tokens[rng.below(tokens.length)];
                auto i = rng.below(b.length + 1);
                b = b[0 .. i] ~ t ~ b[i .. $];
                break;
            }
            case 3: // duplicates a range
                if (b.length)
                {
                    auto i = rng.below(b.length);
                    auto n = 1 + rng.below(32);
                    if (i + n > b.length) n = b.length - i;
                    b = b[0 .. i + n] ~ b[i .. i + n] ~ b[i + n .. $];
                }
                break;
            case 4: // cuts the end
                if (b.length) b = b[0 .. rng.below(b.length + 1)];
                break;
            case 5: // splices in another seed
            {
                auto o = pool[rng.below(pool.length)];
                auto i = rng.below(b.length + 1);
                auto j = rng.below(o.length + 1);
                b = b[0 .. i] ~ o[j .. $];
                break;
            }
            case 6: // bit flip
                if (b.length) b[rng.below(b.length)] ^= cast(char)(1 << rng.below(8));
                break;
            default: // replaces a byte with a control character or space
                if (b.length) b[rng.below(b.length)] = "\r\n\t \0:"[rng.below(6)];
                break;
        }
    }
    return b;
}

void main(string[] args)
{
    immutable iters = args.length > 1 ? args[1].to!size_t : 400_000;
    Rng rng = Rng(args.length > 2 ? args[2].to!ulong : 0x9E3779B97F4A7C15);

    const(char)[][] pool;
    foreach (e; dirEntries("tests/fuzz/corpus", "*.http", SpanMode.shallow))
        pool ~= cast(const(char)[]) read(e.name);
    assert(pool.length, "empty corpus");

    size_t complete, errors, incomplete;
    foreach (i; 0 .. iters)
    {
        auto input = mutate(rng, pool[rng.below(pool.length)], pool);
        check(input);
        // counts only for the report
        import andaime.http.types : Request, HeaderField;
        Request r;
        HeaderField[32] st;
        final switch (parseRequestHead(input, r, st[]).status)
        {
            case ParseStatus.complete: complete++; break;
            case ParseStatus.error: errors++; break;
            case ParseStatus.incomplete: incomplete++; break;
        }
    }
    printf("parser fuzz: %zu inputs (complete %zu, error %zu, incomplete %zu), none violated the invariants\n",
        iters, complete, errors, incomplete);
}
