/// Per-request context and onion-style middleware pipeline.
module vela.web.context;

@safe:

import vela.http.types;
import vela.http.buffer;
import vela.web.dto : FieldErrors;

/// Values of the route's `{params}`, in the order they appear in the pattern.
/// The handler wrapper knows at compile time which index is which name.
struct PathParams
{
    enum size_t max = 8;
    const(char)[][max] values;
    size_t count;

    void push(const(char)[] v) nothrow @nogc @safe
    {
        values[count++] = v; // the registration guarantees count <= max
    }

    void pop() nothrow @nogc @safe
    {
        count--;
    }

    const(char)[] opIndex(size_t i) const nothrow @nogc @safe => values[i];
}

/// Response state. The buffer is reused across requests.
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
        assert(headerCount < headerStore.length, "vela: more than 16 extra response headers");
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

/// Typed per-request storage to pass data from a middleware to the
/// handler (authenticated user, request id...). One value per type:
///
///     ctx.locals.set(User(7, "ana"));          // in the middleware
///     string me(Local!User u) => u.name;       // in the handler
///
/// The boxes are reused across requests: after warm-up it does not allocate.
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

    /// Stores `value` (replaces the previous one of the same type).
    void set(T)(T value)
    {
        size_t free = size_t.max;
        foreach (i, ref sl; slots)
        {
            if (sl.key is typeid(T))
            {
                (cast(TypedBox!T) sl.box).value = value;
                sl.live = true;
                return;
            }
            if (free == size_t.max && sl.key is null)
                free = i;
        }
        assert(free != size_t.max, "vela: more than 8 types in ctx.locals");
        auto b = new TypedBox!T;
        b.value = value;
        slots[free].key = typeid(T);
        slots[free].box = b;
        slots[free].live = true;
    }

    /// Pointer to the value, or null if no middleware set it in this request.
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

/// One object per connection, reused on every request: nothing is allocated
/// per request. Do not keep references to it after the handler returns.
final class Context
{
    Request request;
    PathParams params;
    ResponseState response;
    FieldErrors errors;
    Locals locals;
    package char[64] allowBuf; // value of the 405 Allow header
    private char[512] scratchBuf;
    private size_t scratchUsed;

    /// Temporary memory valid until the end of the request (to build
    /// response header values without allocating). Past 512 bytes, it falls back to the GC.
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

    /// Prepares for a new request without releasing buffers.
    void reset(ref Request r) nothrow @nogc @safe
    {
        request = r;
        params.count = 0;
        response.reset();
        errors.clear();
        locals.reset();
        scratchUsed = 0;
    }

    // ---- shortcuts for middlewares and handlers that receive `Context`

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

/// Onion-style middleware: do something, call `next()`, do something after.
alias Middleware = void delegate(Context ctx, Next next) @safe;

/// Continuation of the pipeline. It is a struct (not a closure): calling `next()`
/// does not allocate. Not calling `next()` stops the chain (e.g. auth denied).
struct Next
{
    private void delegate(Context, size_t) @safe runner;
    private size_t index;
    private Context ctx;

    package this(void delegate(Context, size_t) @safe runner, size_t index, Context ctx) nothrow @nogc @safe
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
