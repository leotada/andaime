/// Pool de buffers por worker, fora do heap do GC.
///
/// Classes de tamanho fixas (4, 16, 64 KiB). Conexões ociosas devolvem o
/// buffer ao pool: 10 mil conexões keep-alive paradas não seguram 160 MiB.
/// O pool guarda no máximo `maxCachedBytes`; o excedente volta ao SO.
/// Single-thread por design (um pool por worker), por isso sem locks.
module vela.engine.bufferpool;

import core.stdc.stdlib : malloc, free;
import core.exception : onOutOfMemoryError;

struct Buffer
{
    ubyte[] mem; /// capacidade total
    size_t len;  /// bytes válidos
    ubyte cls;   /// classe de tamanho (para devolver ao pool certo)

    bool isNull() const nothrow @nogc @safe => mem.length == 0;
    ubyte[] data() nothrow @nogc @safe return => mem[0 .. len];
    ubyte[] free_() nothrow @nogc @safe return => mem[len .. $];

    /// Move os bytes ainda não consumidos para o início (após o parse de
    /// uma requisição em pipelining). Mantém o head contíguo para o parser.
    void compact(size_t consumed) nothrow @nogc @trusted
    {
        import core.stdc.string : memmove;

        immutable rest = len - consumed;
        if (rest && consumed)
            memmove(mem.ptr, mem.ptr + consumed, rest);
        len = rest;
    }
}

struct BufferPool
{
    static immutable size_t[3] classSize = [4 << 10, 16 << 10, 64 << 10];

    private ubyte[][][3] free_;
    private size_t cachedBytes;
    size_t maxCachedBytes = 2 << 20; /// teto do cache por worker (2 MiB)
    size_t outstanding;              /// buffers emprestados agora (métrica)

    @disable this(this);

    ~this() @trusted nothrow @nogc
    {
        foreach (ref list; free_)
            foreach (b; list)
                free(b.ptr);
    }

    /// Empresta um buffer com pelo menos `minSize` bytes.
    Buffer acquire(size_t minSize) @trusted nothrow
    {
        ubyte c = 0;
        while (c < classSize.length && classSize[c] < minSize)
            c++;
        if (c == classSize.length)
            assert(0, "vela: buffer maior que a maior classe; checar Limits antes");
        outstanding++;
        if (free_[c].length)
        {
            auto m = free_[c][$ - 1];
            free_[c] = free_[c][0 .. $ - 1];
            cachedBytes -= m.length;
            return Buffer(m, 0, c);
        }
        auto p = cast(ubyte*) malloc(classSize[c]);
        if (p is null)
            onOutOfMemoryError();
        return Buffer(p[0 .. classSize[c]], 0, c);
    }

    /// Devolve. Acima do teto, libera direto para o SO.
    void release(ref Buffer b) @trusted nothrow
    {
        if (b.isNull)
            return;
        outstanding--;
        if (cachedBytes + b.mem.length <= maxCachedBytes)
        {
            free_[b.cls] ~= b.mem; // a lista em si é pequena e estável após o aquecimento
            cachedBytes += b.mem.length;
        }
        else
            free(b.mem.ptr);
        b = Buffer.init;
    }

    /// Promove para a próxima classe preservando os dados (corpo grande).
    bool grow(ref Buffer b, size_t minSize) @trusted nothrow
    {
        if (minSize > classSize[$ - 1])
            return false;
        auto nb = acquire(minSize);
        nb.mem[0 .. b.len] = b.mem[0 .. b.len];
        nb.len = b.len;
        release(b);
        b = nb;
        return true;
    }
}

unittest
{
    BufferPool pool;
    auto a = pool.acquire(100);
    assert(a.mem.length == 4096 && pool.outstanding == 1);
    a.mem[0 .. 3] = cast(ubyte[]) "abc";
    a.len = 3;
    assert(pool.grow(a, 10_000) && a.mem.length == 16 << 10 && a.data == cast(ubyte[]) "abc");
    auto p = a.mem.ptr;
    pool.release(a);
    assert(a.isNull && pool.outstanding == 0);
    auto b = pool.acquire(5000);
    assert(b.mem.ptr is p); // reaproveitado, sem malloc
    pool.release(b);
}
