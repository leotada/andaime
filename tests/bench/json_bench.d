module json_bench 2025;
/// Why andaime has its own JSON reader/writer: decodes a DTO and encodes it back, with andaime and with `std.json`, and prints
/// time and GC bytes per operation. Not part of `check.sh` (timings are noisy); run it through `tools/json_bench.sh`.
/// `std.json` has no typed decoding or encoding, so its side does what a handler would have to do by hand: parse the tree, then
/// copy it into the struct (and the other way round to write).
import andaime;
import order;
import core.memory : GC;
import core.time : MonoTime;
import std.json : JSONType, parseJSON;
import std.stdio : writefln;

/// Runs `fn` `n` times; prints microseconds and GC bytes per call, and returns the microseconds.
double measure(string label, size_t n, scope void delegate() fn)
{
    foreach (_; 0 .. n / 10 + 1)
        fn(); // warm-up
    GC.collect();
    const bytes0 = GC.allocatedInCurrentThread;
    const t0 = MonoTime.currTime;
    foreach (_; 0 .. n)
        fn();
    const us = (MonoTime.currTime - t0).total!"nsecs" / 1000.0 / n;
    const bytes = (GC.allocatedInCurrentThread - bytes0) / n;
    writefln("  %-28s %9.2f us/op %10s B/op", label, us, bytes);
    return us;
}

int main()
{
    enum n = 20_000;
    auto order = sample();
    const text = toJson(order);
    writefln("payload: %s bytes, %s items", text.length, order.items.length);

    // The two sides must agree before the numbers mean anything.
    if (fromJson!Order(text) != viaStd(text) || parseJSON(toStd(order)).toString != parseJSON(text).toString)
    {
        writefln("json_bench: andaime and std.json disagree");
        return 1;
    }

    size_t sink;
    writefln("decode into Order:");
    const a = measure("andaime fromJson", n, { sink += fromJson!Order(text).items.length; });
    const s = measure("std.json parse + copy", n, { sink += viaStd(text).items.length; });
    writefln("  -> andaime is %.1fx faster", s / a);

    writefln("parse to a tree:");
    const a2 = measure("andaime parseJson", n, { sink += parseJson(text).isObject ? 1 : 0; });
    const s2 = measure("std.json parseJSON", n, { sink += parseJSON(text).type == JSONType.object ? 1 : 0; });
    writefln("  -> andaime is %.1fx faster", s2 / a2);

    writefln("encode Order:");
    const a3 = measure("andaime toJson", n, { sink += toJson(order).length; });
    const s3 = measure("std.json JSONValue.toString", n, { sink += toStd(order).length; });
    writefln("  -> andaime is %.1fx faster", s3 / a3);

    return sink == 0 ? 1 : 0; // keeps the work observable
}
