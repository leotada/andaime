/// Contexto por requisição e pipeline de middleware em cebola.
module vela.web.context;

import vela.http.types;
import vela.http.buffer;
import vela.web.dto : FieldErrors;

/// Valores dos `{params}` da rota, na ordem em que aparecem no padrão.
/// O wrapper do handler sabe em compilação qual índice é qual nome.
struct PathParams
{
    enum size_t max = 8;
    const(char)[][max] values;
    size_t count;

    void push(const(char)[] v) nothrow @nogc @safe
    {
        values[count++] = v; // o registro garante count <= max
    }

    void pop() nothrow @nogc @safe
    {
        count--;
    }

    const(char)[] opIndex(size_t i) const nothrow @nogc @safe => values[i];
}

/// Estado da resposta. O buffer é reaproveitado entre requisições.
struct ResponseState
{
    int status = 200;
    const(char)[] contentType;
    ByteBuffer body;
    private HeaderField[16] headerStore;
    private size_t headerCount;

    void setHeader(const(char)[] name, const(char)[] value) nothrow @nogc @safe
    {
        foreach (ref h; headerStore[0 .. headerCount])
            if (equalsIgnoreCase(h.name, name))
            {
                h.value = value;
                return;
            }
        assert(headerCount < headerStore.length, "vela: mais de 16 headers extras na resposta");
        headerStore[headerCount++] = HeaderField(name, value);
    }

    const(HeaderField)[] headers() const nothrow @nogc @safe return => headerStore[0 .. headerCount];

    void reset() nothrow @nogc @safe
    {
        status = 200;
        contentType = null;
        body.clear();
        headerCount = 0;
    }
}

/// Armazenamento tipado por requisição para passar dados de um middleware ao
/// handler (usuário autenticado, id da requisição...). Um valor por tipo:
///
///     ctx.locals.set(User(7, "ana"));          // no middleware
///     string me(Local!User u) => u.name;       // no handler
///
/// As caixas são reaproveitadas entre requisições: depois do aquecimento não aloca.
struct Locals
{
    private static class Box { }
    private static final class TypedBox(T) : Box { T value; }

    private struct Slot
    {
        TypeInfo key;
        Box box;
        bool live;
    }

    enum size_t capacity = 8;
    private Slot[capacity] slots;

    /// Guarda `value` (substitui o anterior do mesmo tipo).
    void set(T)(T value)
    {
        Slot* free;
        foreach (ref sl; slots)
        {
            if (sl.key is typeid(T))
            {
                (cast(TypedBox!T) sl.box).value = value;
                sl.live = true;
                return;
            }
            if (free is null && sl.key is null)
                free = &sl;
        }
        assert(free !is null, "vela: mais de 8 tipos em ctx.locals");
        auto b = new TypedBox!T;
        b.value = value;
        free.key = typeid(T);
        free.box = b;
        free.live = true;
    }

    /// Ponteiro para o valor, ou null se nenhum middleware o definiu nesta requisição.
    T* find(T)() return
    {
        foreach (ref sl; slots)
            if (sl.live && sl.key is typeid(T))
                return &(cast(TypedBox!T) sl.box).value;
        return null;
    }

    void reset() nothrow @nogc @safe
    {
        foreach (ref sl; slots)
            sl.live = false;
    }
}

/// Um objeto por conexão, reutilizado a cada requisição: nada é alocado
/// por requisição. Não guarde referências a ele depois que o handler retorna.
final class Context
{
    Request request;
    PathParams params;
    ResponseState response;
    FieldErrors errors;
    Locals locals;
    package char[64] allowBuf; // valor do header Allow do 405
    private char[512] scratchBuf;
    private size_t scratchUsed;

    /// Memória temporária válida até o fim da requisição (para montar valores de
    /// headers de resposta sem alocar). Passou de 512 bytes, cai no GC.
    char[] scratch(size_t n) nothrow @trusted
    {
        if (scratchUsed + n <= scratchBuf.length)
        {
            auto r = scratchBuf[scratchUsed .. scratchUsed + n];
            scratchUsed += n;
            return r;
        }
        return new char[n];
    }

    /// Prepara para uma nova requisição sem liberar buffers.
    void reset(ref Request r) nothrow @nogc @safe
    {
        request = r;
        params.count = 0;
        response.reset();
        errors.clear();
        locals.reset();
        scratchUsed = 0;
    }

    // ---- atalhos para middlewares e handlers que recebem `Context`

    void setHeader(const(char)[] name, const(char)[] value) nothrow @nogc @safe
    {
        response.setHeader(name, value);
    }

    void text(const(char)[] s, int status = 200) nothrow @nogc @safe
    {
        response.status = status;
        response.contentType = "text/plain; charset=utf-8";
        response.body.clear();
        response.body.put(s);
    }
}

/// Middleware em cebola: faça algo, chame `next()`, faça algo depois.
alias Middleware = void delegate(Context ctx, Next next);

/// Continuação do pipeline. É um struct (não um closure): chamar `next()`
/// não aloca. Não chamar `next()` interrompe a cadeia (ex.: auth negada).
struct Next
{
    private void delegate(Context, size_t) runner;
    private size_t index;
    private Context ctx;

    package this(void delegate(Context, size_t) runner, size_t index, Context ctx) nothrow @nogc @safe
    {
        this.runner = runner;
        this.index = index;
        this.ctx = ctx;
    }

    void opCall()
    {
        runner(ctx, index);
    }
}
