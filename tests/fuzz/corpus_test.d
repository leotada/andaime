/// Corpus de requisições do parser: cada arquivo `nome.<resultado>.http` traz os
/// bytes de uma requisição e o resultado esperado (`ok`, `incomplete` ou o status
/// de erro: 400, 413...). Para cobrir um ataque novo, basta colocar um arquivo aqui.
module corpus_test;

import vela.http.parser;
import vela.http.types;
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
            printf("FALHOU %s: esperado %s, obteve %s\n", e.name.ptr, expected.ptr, got.ptr);
        }
    }
    printf("corpus do parser: %zu casos, %zu falhas\n", n, bad);
    if (bad || n == 0)
        throw new Exception("corpus do parser falhou");
}
