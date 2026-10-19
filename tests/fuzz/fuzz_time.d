/// Mutation fuzzer for `Timestamp` and `CalendarDate` text (runs in check.sh, deterministic per seed): starts from valid
/// dates and date-times (leap days, the range's ends, every offset form, long fractions, Postgres' text) and breaks them
/// at the byte and token level.
/// Usage: fuzz_time [iterations] [seed]
module fuzz_time 2025;

import time_invariants;
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
    return [
        t("2026-10-19T12:00:00Z"), t("2026-10-19 12:00:00.123456+00"), t("2026-10-19t09:00:00.5-03"),
        t("2024-02-29T23:59:59.9999995+05:30"), t("0001-01-01T00:00:00-18:00"), t("9999-12-31T23:59:59.999999+18:00"),
        t("1900-01-01 00:00:00-03:06:00"), t("2026-12-31T23:59:59.99999949999999999z"), t("2000-02-29T00:00:00+0530"),
        t("2026-10-19"), t("2024-02-29"), t("0001-01-01"), t("9999-12-31"),
    ];
}

ubyte[] mutate(ref Rng rng, const(ubyte)[] src, ubyte[][] pool)
{
    static immutable string[] tokens = ["-", ":", ".", "T", " ", "Z", "+", "+00", "-03:00", "+05:30", ":00", "9", "0",
        "60", "24", "29", "02-29", "99999", "\xff", "\x00", "infinity", "BC"];
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
                immutable n = rng.below(4);
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
            case 5: // change a digit (dates and times at their edges)
                if (b.length)
                {
                    immutable i = rng.below(b.length);
                    if (b[i] >= '0' && b[i] <= '9')
                        b[i] = cast(ubyte)('0' + rng.below(10));
                }
                break;
        }
    }
    return b;
}

void main(string[] args)
{
    if (args.length > 2 && args[1] == "--seeds") // libFuzzer's starting corpus (tools/fuzz.sh time)
    {
        import std.file : write;

        foreach (i, s; seeds())
            write(args[2] ~ "/seed" ~ i.to!string ~ ".txt", s);
        return;
    }
    immutable iterations = args.length > 1 ? args[1].to!size_t : 100_000;
    auto rng = Rng(args.length > 2 ? args[2].to!ulong : 0x9e3779b97f4a7c15);
    auto pool = seeds();
    foreach (s; pool)
        checkTime(s);
    foreach (i; 0 .. iterations)
        checkTime(mutate(rng, pool[rng.below(pool.length)], pool));
    printf("time fuzz: %zu inputs, invariants held\n", iterations);
}
