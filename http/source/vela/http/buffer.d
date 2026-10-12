/// Buffer de bytes crescente alocado fora do heap do GC.
/// Não contém ponteiros para o GC, então o coletor nunca o escaneia.
module vela.http.buffer;

import core.stdc.stdlib : malloc, realloc, free;
import core.exception : onOutOfMemoryError;

struct ByteBuffer
{
    private char* ptr;
    private size_t len;
    private size_t cap;

    @disable this(this); // dono único: evita double free

    ~this() @trusted nothrow @nogc
    {
        free(ptr);
    }

    size_t length() const pure nothrow @nogc @safe => len;
    size_t capacity() const pure nothrow @nogc @safe => cap;

    /// Fatia válida até a próxima escrita ou `clear`.
    const(char)[] data() const pure nothrow @nogc @trusted return
    {
        return ptr[0 .. len];
    }

    void clear() pure nothrow @nogc @safe
    {
        len = 0;
    }

    void reserve(size_t extra) nothrow @nogc @trusted
    {
        if (len + extra <= cap)
            return;
        size_t n = cap ? cap : 256;
        while (n < len + extra)
            n *= 2;
        auto p = cast(char*) realloc(ptr, n);
        if (p is null)
            onOutOfMemoryError();
        ptr = p;
        cap = n;
    }

    void put(scope const(char)[] s) nothrow @nogc @trusted
    {
        reserve(s.length);
        ptr[len .. len + s.length] = s[];
        len += s.length;
    }

    /// Espaço livre de `n` bytes no fim do buffer, para escrever direto (read(2), pread...).
    /// Depois chame `commit(k)` com quantos bytes foram escritos de fato.
    char[] writable(size_t n) nothrow @nogc @trusted
    {
        reserve(n);
        return ptr[len .. len + n];
    }

    void commit(size_t n) nothrow @nogc @safe
    {
        assert(len + n <= cap, "vela: commit além do espaço reservado");
        len += n;
    }

    void put(char c) nothrow @nogc @trusted
    {
        reserve(1);
        ptr[len++] = c;
    }

    /// Inteiro decimal sem std.conv e sem alocar.
    void putInt(long v) nothrow @nogc @safe
    {
        char[20] tmp = void;
        size_t i = tmp.length;
        ulong u = v < 0 ? (cast(ulong)(-(v + 1))) + 1 : cast(ulong) v;
        do
        {
            tmp[--i] = cast(char)('0' + u % 10);
            u /= 10;
        }
        while (u);
        if (v < 0)
            put('-');
        put(tmp[i .. $]);
    }

    void putUint(ulong u) nothrow @nogc @safe
    {
        char[20] tmp = void;
        size_t i = tmp.length;
        do
        {
            tmp[--i] = cast(char)('0' + u % 10);
            u /= 10;
        }
        while (u);
        put(tmp[i .. $]);
    }

    /// Formato curto que faz round-trip (%.17g). NaN/Inf viram `null` (JSON).
    void putFloat(double d) nothrow @nogc @trusted
    {
        import core.stdc.stdio : snprintf;

        if (d != d || d == double.infinity || d == -double.infinity)
        {
            put("null");
            return;
        }
        char[32] tmp = void;
        int n = snprintf(tmp.ptr, tmp.length, "%.17g", d);
        put(tmp[0 .. n]);
    }

    /// Devolve memória se o buffer cresceu além de `maxKeep` (ex.: depois de
    /// uma resposta grande), para o RSS não ficar preso ao pico.
    void shrinkTo(size_t maxKeep) nothrow @nogc @trusted
    {
        if (cap <= maxKeep)
            return;
        free(ptr);
        ptr = null;
        len = cap = 0;
    }
}

unittest
{
    ByteBuffer b;
    b.put("x=");
    b.putInt(-1234);
    b.put(' ');
    b.putInt(long.min);
    b.put(' ');
    b.putFloat(0.5);
    assert(b.data == "x=-1234 -9223372036854775808 0.5", b.data);
    b.clear();
    assert(b.length == 0 && b.capacity >= 32);
}
