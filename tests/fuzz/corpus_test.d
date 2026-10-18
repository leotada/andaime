/// Parser request corpus: each file `name.<result>.http` holds the
/// bytes of a request and the expected result (`ok`, `incomplete` or the error
/// status: 400, 413...). To cover a new attack, just drop a file in here.
module corpus_test 2025;

import andaime.http.parser;
import andaime.http.types;
import core.stdc.stdio : printf;
import std.file : dirEntries, SpanMode, read;
import std.path : baseName, stripExtension, extension;
import std.conv : to;

void main()
{
    HeaderField[32] store;
    size_t n, bad;
    foreach (e; dirEntries("tests/fuzz/corpus", "*.http", SpanMode.shallow))
    {
        auto data = cast(const(char)[]) read(e.name);
        auto expected = e.name.baseName.stripExtension.extension[1 .. $];
        Request r;
        auto h = parseRequestHead(data, r, store[]);
        string got;
        final switch (h.status)
        {
            case ParseStatus.complete: got = "ok"; break;
            case ParseStatus.incomplete: got = "incomplete"; break;
            case ParseStatus.error: got = h.errorStatus.to!string; break;
        }
        n++;
        if (got != expected)
        {
            bad++;
            printf("FAILED %s: expected %s, got %s\n", e.name.ptr, expected.ptr, got.ptr);
        }
    }
    printf("parser corpus: %zu cases, %zu failures\n", n, bad);
    if (bad || n == 0)
        throw new Exception("parser corpus failed");
}
