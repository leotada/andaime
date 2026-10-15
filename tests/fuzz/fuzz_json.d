/// Mutation fuzzer for the JSON reader (runs in check.sh, deterministic per seed): starts from valid documents (deep
/// nesting, escapes, numbers at the edges, repeated keys) and breaks them at the byte and token level.
/// Usage: fuzz_json [iterations] [seed]
module fuzz_json;

import json_invariants;
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

ubyte[] t(string s) => cast(ubyte[]) s.dup;

ubyte[][] seeds()
{
    string deep;
    foreach (i; 0 .. 20)
        deep ~= `{"a":[`;
    deep ~= "1";
    foreach (i; 0 .. 20)
        deep ~= `]}`;
    string many = "{";
    foreach (i; 0 .. 30)
        many ~= `"k` ~ (i % 12).to!string ~ `":` ~ i.to!string ~ ",";
    many ~= `"z":null}`;
    return [
        t(`{"name":"Ana","id":7,"items":[{"n":1,"s":"x"},{"n":2,"s":null}],"scores":{"a":1.5,"b":-2e-3},"extra":[true,false,null]}`),
        t(`{"name":"ç😀\"\\\/\b\f\n\r\t","id":null,"items":[],"scores":{},"extra":{"k":{"k":{}}}}`),
        t(`[0,-0,0.5,-1.25e-3,1E5,9223372036854775807,-9223372036854775808,9223372036854775808,1e308,4.9e-324]`),
        t(`"just a string"`), t(`true`), t(`null`), t(`-12`), t(`[]`), t(`{}`),
        t(deep), t(many),
        t("{\"a\":\"\xc3\xa7\",\"b\":\"\xe2\x82\xac\"}"),
    ];
}

ubyte[] mutate(ref Rng rng, const(ubyte)[] src, ubyte[][] pool)
{
    static immutable string[] tokens = [`{`, `}`, `[`, `]`, `,`, `:`, `"`, `\`, `\u`, `\ud800`, `null`, `true`, `-`, `0`,
        `1e`, `.`, `e+`, "\xff", "\xc3", "\x00", ` `, `"k":`, `[[[[[[[[[[[[[[[[[[`, `]]]]]]]]]`];
    auto b = src.dup;
    immutable rounds = 1 + rng.below(4);
    foreach (_; 0 .. rounds)
    {
        immutable at = rng.below(b.length + 1);
        final switch (rng.below(6))
        {
            case 0: // flip a byte
                if (b.length)
                    b[rng.below(b.length)] ^= cast(ubyte)(1 << rng.below(8));
                break;
            case 1: // insert a token
                b = b[0 .. at] ~ cast(const(ubyte)[]) tokens[rng.below(tokens.length)] ~ b[at .. $];
                break;
            case 2: // delete a range
                immutable n = rng.below(8);
                if (at + n <= b.length)
                    b = b[0 .. at] ~ b[at + n .. $];
                break;
            case 3: // truncate
                b = b[0 .. at];
                break;
            case 4: // splice another seed in
                auto other = pool[rng.below(pool.length)];
                immutable from = rng.below(other.length + 1);
                b = b[0 .. at] ~ other[from .. $];
                break;
            case 5: // duplicate a range (repeated keys, deeper nesting)
                immutable n = rng.below(16);
                if (at + n <= b.length)
                    b = b[0 .. at + n] ~ b[at .. $];
                break;
        }
    }
    return b;
}

void main(string[] args)
{
    if (args.length > 2 && args[1] == "--seeds") // libFuzzer's starting corpus (tools/fuzz.sh json)
    {
        import std.file : write;

        foreach (i, s; seeds())
            write(args[2] ~ "/seed" ~ i.to!string ~ ".json", s);
        return;
    }
    immutable iterations = args.length > 1 ? args[1].to!size_t : 100_000;
    auto rng = Rng(args.length > 2 ? args[2].to!ulong : 0x9e3779b97f4a7c15);
    auto pool = seeds();
    foreach (s; pool)
        checkJson(s);
    foreach (i; 0 .. iterations)
        checkJson(mutate(rng, pool[rng.below(pool.length)], pool));
    printf("JSON fuzz: %zu inputs, invariants held\n", iterations);
}
