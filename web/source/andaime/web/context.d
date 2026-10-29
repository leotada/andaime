/// Per-request context and onion-style middleware pipeline.
module andaime.web.context 2025;

@safe:

import andaime.http.types;
import andaime.http.buffer;
import andaime.http.response : ResponseSink;
import andaime.http.websocket : WsDeflateFactory;
import andaime.http.ip : IpAddress, Cidr, parseIp;
import andaime.web.dto : FieldError, FieldErrors;
import andaime.web.uploads : SpoolConfig;

/// Per-Context state of the request body (see `Context.bodyState`).
package(andaime) final class BodyState
{
    size_t pos;                  /// bytes of a buffered `request.body` that `readBodyInto` already handed out
    const(SpoolConfig)* spool;   /// set by `App.handle`: where `SpooledFile` parts go
    string[] spooledFiles;       /// temporary files of this request, removed when `App.handle` ends
}

/// A request body's buffer: a `NO_SCAN` GC block like the engine's (see `andaime.http.buffer`).
private ubyte[] bodyBlock(size_t n) nothrow @trusted
{
    // sound: allocBlock returns a fresh block of exactly n bytes that nothing else references
    return n ? (cast(ubyte*) allocBlock(n))[0 .. n] : null;
}

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
///
/// Headers: `setHeader` replaces every header of that name, `addHeader` appends (several `Set-Cookie`, `Link`...).
/// Names and values are checked once, after the middleware chain has unwound (`App.handle`): a CR, LF, NUL or other
/// control character, an invalid name, or more than `maxHeaders` headers turns the response into a 500 and a log
/// line. andaime owns `Content-Length` (always the body size), `Connection`, `Keep-Alive`, `Transfer-Encoding`,
/// `Upgrade`, `Proxy-Connection` and `TE`: whatever the application sets for them is dropped. `Date` is added by the
/// server unless the application set it.
struct ResponseState
{
    /// Headers the application may set; one extra slot is reserved for the server's `Date`.
    enum size_t maxHeaders = 32;

    int status = 200;
    const(char)[] contentType;
    ByteBuffer body;
    private HeaderField[maxHeaders + 1] headerStore;
    private size_t headerCount;
    private bool overflowed;
    private bool locked, lockedWarned;

    /// Once a streamed response has started its status and headers are on the wire: later changes are ignored (and
    /// logged once per request).
    void lock() nothrow @nogc @safe
    {
        locked = true;
    }

    bool isLocked() const nothrow @nogc @safe => locked;

    /// Sets the header, replacing any existing one with the same name (case-insensitive).
    void setHeader(const(char)[] name, const(char)[] value) nothrow @nogc @safe
    {
        if (locked)
            return warnLocked(name);
        bool found;
        size_t i;
        while (i < headerCount)
        {
            if (equalsIgnoreCase(headerStore[i].name, name))
            {
                if (!found)
                {
                    headerStore[i].value = value;
                    found = true;
                    i++;
                }
                else
                    removeAt(i);
            }
            else
                i++;
        }
        if (!found)
            append(name, value);
    }

    /// Appends a header even if one with the same name exists (`Set-Cookie`, `Link`, `Warning`...).
    void addHeader(const(char)[] name, const(char)[] value) nothrow @nogc @safe
    {
        if (locked)
            return warnLocked(name);
        append(name, value);
    }

    /// Removes every header with that name.
    void removeHeader(const(char)[] name) nothrow @nogc @safe
    {
        if (locked)
            return;
        size_t i;
        while (i < headerCount)
            if (equalsIgnoreCase(headerStore[i].name, name))
                removeAt(i);
            else
                i++;
    }

    /// Sets the header only if the application did not; for headers the server adds (`Date`). Uses the reserved slot.
    void ensureHeader(const(char)[] name, const(char)[] value) nothrow @nogc @safe
    {
        foreach (ref h; headerStore[0 .. headerCount])
            if (equalsIgnoreCase(h.name, name))
                return;
        if (headerCount < headerStore.length)
            headerStore[headerCount++] = HeaderField(name, value);
    }

    /// First value of the header, or null.
    const(char)[] header(scope const(char)[] name) const nothrow @nogc @safe
    {
        foreach (ref h; headerStore[0 .. headerCount])
            if (equalsIgnoreCase(h.name, name))
                return h.value;
        return null;
    }

    /// True if the application tried to set more than `maxHeaders` headers.
    bool headerOverflow() const nothrow @nogc @safe => overflowed;

    const(HeaderField)[] headers() const nothrow @nogc @safe return => headerStore[0 .. headerCount];

    void reset() nothrow @nogc @safe
    {
        status = 200;
        contentType = null;
        body.clear();
        headerCount = 0;
        overflowed = false;
        locked = lockedWarned = false;
    }

    private void warnLocked(scope const(char)[] name) nothrow @nogc @trusted
    {
        import core.stdc.stdio : fprintf, stderr;

        if (lockedWarned)
            return;
        lockedWarned = true;
        // @trusted: fprintf with an explicit length; the name is only printed
        fprintf(stderr, "andaime: header '%.*s' set after the response started; ignored\n", cast(int) name.length, name.ptr);
    }

    /// Drops every header (used when the response is replaced by an error).
    void clearHeaders() nothrow @nogc @safe
    {
        headerCount = 0;
        overflowed = false;
    }

    private void append(const(char)[] name, const(char)[] value) nothrow @nogc @safe
    {
        if (headerCount >= maxHeaders)
        {
            overflowed = true;
            return;
        }
        headerStore[headerCount++] = HeaderField(name, value);
    }

    private void removeAt(size_t i) nothrow @nogc @safe
    {
        foreach (j; i + 1 .. headerCount)
            headerStore[j - 1] = headerStore[j];
        headerCount--;
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
        assert(free != size_t.max, "andaime: more than 8 types in ctx.locals");
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

/// Which proxies are believed about `X-Forwarded-For` (see `App.trustProxies`).
struct ProxyTrust
{
    Cidr[] nets;
    string header = "X-Forwarded-For";

    bool trusts(const IpAddress a) const pure nothrow @nogc
    {
        foreach (ref n; nets)
            if (n.contains(a))
                return true;
        return false;
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
    /// Set by `App.handle`: the proxies whose forwarding header is believed.
    const(ProxyTrust)* proxies;
    /// Where the response goes (the engine's sink, or a recording one in tests). Needed only by streamed responses.
    ResponseSink sink;
    /// Length announced for a streamed response (-1 = unknown); see `Stream.contentLength`.
    long streamLength = -1;
    /// A streamed response's head was handed to the sink: status and headers are final.
    bool committed;
    /// The handler failed after the commit: the response can only be cut off (see `ResponseAborted`).
    bool aborted;
    /// Creates a connection's permessage-deflate state (zlib, set by the server); null: WebSockets are not compressed.
    WsDeflateFactory newDeflate;
    /// Set by `App` for the matched route: answers a request whose parameters failed to bind (`App.onValidationError`).
    /// Null: the default 422.
    package void delegate(Context) @safe onValidation;
    /// Set by `App` when it has `validationMessages`: the message of one validation error, in the app's language. Null:
    /// the English text the rule wrote.
    package string delegate(ref const FieldError) @safe messageOf;
    /// The request id the logger adds to lines written during this request (set by the `requestId` middleware).
    package(andaime) const(char)[] requestIdForLog;

    /// `andaime.log`'s view of this request: its id (a method, so the logger takes it as a delegate without allocating).
    package(andaime) const(char)[] logRequestId() nothrow => requestIdForLog;
    package char[48] allowBuf; // value of the 405 Allow header: at most the 7 methods, 43 bytes
    private char[512] scratchBuf;
    private size_t scratchUsed;
    // what reading the body needs, created once per Context (a separate object: Context must stay within 4096 bytes)
    private BodyState bodyState_;

    package(andaime) BodyState bodyState() nothrow
    {
        if (bodyState_ is null)
            bodyState_ = new BodyState;
        return bodyState_;
    }

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
    void reset(ref Request r, ResponseSink sink = null) nothrow @nogc @safe
    {
        request = r;
        this.sink = sink;
        committed = aborted = false;
        onValidation = null;
        messageOf = null;
        requestIdForLog = null;
        streamLength = -1;
        params.count = 0;
        response.reset();
        errors.clear();
        locals.reset();
        scratchUsed = 0;
        if (bodyState_ !is null)
            bodyState_.pos = 0;
    }

    // ---- the request body

    /// Copies up to `into.length` bytes of the body into `into` and returns how many; 0 = the end. The same for a
    /// buffered body and for one still arriving (`request.bodyReader`); `BodyStream` is the handler-facing view.
    size_t readBodyInto(scope ubyte[] into)
    {
        if (request.bodyReader !is null)
            return request.bodyReader.read(into);
        auto st = bodyState;
        immutable left = request.body.length - st.pos;
        immutable n = into.length < left ? into.length : left;
        into[0 .. n] = request.body[st.pos .. st.pos + n];
        st.pos += n;
        return n;
    }

    /// Bytes of the body `readBodyInto` has not handed out yet.
    ulong bodyUnread() const
    {
        if (request.bodyReader !is null)
            return request.bodyReader.unread;
        return request.body.length - (bodyState_ is null ? 0 : bodyState_.pos);
    }

    /// The body in memory: a body still arriving (`request.bodyReader`) is read, what is left of it, into one buffer of
    /// its size, which becomes `request.body`. `App` does this before the middleware for every route that does not
    /// stream its body, so a middleware or handler that reads `request.body` sees it whole.
    const(ubyte)[] readBody()
    {
        auto reader = request.bodyReader;
        if (reader is null)
            return request.body[(bodyState_ is null ? 0 : bodyState_.pos) .. $];
        auto block = bodyBlock(cast(size_t) reader.unread);
        size_t got;
        while (got < block.length)
        {
            immutable n = reader.read(block[got .. $]);
            if (n == 0)
                break;
            got += n;
        }
        request.body = block[0 .. got];
        request.bodyReader = null;
        bodyState.pos = 0;
        return request.body;
    }

    // ---- shortcuts for middlewares and handlers that receive `Context`

    /// The client's address. For a request that arrives from a trusted proxy (`App.trustProxies`, or
    /// `ServerConfig.trustedProxies`) it is the first address in the forwarding header, walking from the right, that is
    /// not itself a trusted proxy; an invalid entry stops the walk and the TCP peer is returned. From any other peer the
    /// header is ignored, because anyone can send it. Does not allocate.
    IpAddress clientIp() const nothrow @nogc
    {
        auto peer = request.peer;
        if (proxies is null || proxies.nets.length == 0 || !proxies.trusts(peer))
            return peer;
        // every entry of every header with that name, left to right (only the last 32 matter)
        const(char)[][32] entries;
        size_t n;
        foreach (ref h; request.headers)
        {
            if (!equalsIgnoreCase(h.name, proxies.header))
                continue;
            auto v = h.value;
            size_t start = 0;
            for (size_t i = 0; i <= v.length; i++)
            {
                if (i < v.length && v[i] != ',')
                    continue;
                auto e = v[start .. i];
                while (e.length && (e[0] == ' ' || e[0] == '\t')) e = e[1 .. $];
                while (e.length && (e[$ - 1] == ' ' || e[$ - 1] == '\t')) e = e[0 .. $ - 1];
                start = i + 1;
                if (n == entries.length)
                {
                    foreach (k; 1 .. entries.length)
                        entries[k - 1] = entries[k];
                    n--;
                }
                entries[n++] = e;
            }
        }
        IpAddress last = peer;
        foreach_reverse (e; entries[0 .. n])
        {
            IpAddress a;
            if (!parseIp(e, a))
                return peer;
            a.port = 0;
            if (!proxies.trusts(a))
                return a;
            last = a;
        }
        return last; // every hop is a trusted proxy: the leftmost is the best answer there is
    }

    /// Sets a response header, replacing any with the same name. See `ResponseState` for the rules.
    void setHeader(const(char)[] name, const(char)[] value) nothrow @nogc @safe
    {
        response.setHeader(name, value);
    }

    /// Appends a response header without touching existing ones (`Set-Cookie`, `Link`...).
    void addHeader(const(char)[] name, const(char)[] value) nothrow @nogc @safe
    {
        response.addHeader(name, value);
    }

    /// Adds a token to the `Vary` header ("Origin" -> `Vary: Accept-Encoding, Origin`), keeping one header and no
    /// duplicates. `token` must outlive the request (a literal). Uses the context's scratch memory.
    void addVary(const(char)[] token) nothrow @safe
    {
        auto cur = response.header("Vary");
        if (cur.length == 0)
        {
            response.setHeader("Vary", token);
            return;
        }
        // already there (or "*")?
        size_t i = 0;
        while (i < cur.length)
        {
            while (i < cur.length && (cur[i] == ' ' || cur[i] == ','))
                i++;
            size_t j = i;
            while (j < cur.length && cur[j] != ',')
                j++;
            size_t e = j;
            while (e > i && cur[e - 1] == ' ')
                e--;
            if (e > i && (cur[i .. e] == "*" || equalsIgnoreCase(cur[i .. e], token)))
                return;
            i = j;
        }
        auto buf = scratch(cur.length + 2 + token.length);
        buf[0 .. cur.length] = cur[];
        buf[cur.length .. cur.length + 2] = ", ";
        buf[cur.length + 2 .. $] = token[];
        response.setHeader("Vary", buf);
    }

    void text(const(char)[] s, int status = 200) nothrow @nogc @safe
    {
        response.status = status;
        response.contentType = "text/plain; charset=utf-8";
        response.body.clear();
        response.body.put(s);
    }

    /// Answers `value` as JSON (any type a handler may return as JSON: a struct, an array, a map...), replacing the
    /// body. For error and validation handlers: `ctx.json(ApiError("invalid email"), 400);`
    void json(T)(auto ref const T value, int status = 200)
    {
        import andaime.web.json : writeJson;

        response.status = status;
        response.contentType = "application/json";
        response.body.clear();
        writeJson(response.body, value);
    }
}

// A `Context` lives in the GC heap, one per request in flight, and 4096 bytes is the largest size class below a page
// multiple: one byte more doubles what 1,000 concurrent requests cost (the 30 MB ceiling in tools/check.sh). The sixteen
// preallocated `FieldError`s are most of it (`FieldParams` is kept small for that reason).
static assert(__traits(classInstanceSize, Context) <= 4096, "andaime: Context outgrew the GC's 4096-byte size class");

/// Onion-style middleware: do something, call `next()`, do something after.
/// The type is `@system` on purpose: it accepts `@safe` and `@system` delegates alike, so user code may
/// call C libraries without ceremony. `@safe` code converts to it implicitly and stays checked by the
/// compiler (put `@safe:` at the top of your module). The framework calls it through `callMiddleware`.
alias Middleware = void delegate(Context ctx, Next next) @system;

/// The single place where a user middleware is invoked from `@safe` framework code.
/// @trusted: the callee's own safety is the user's business; nothing here touches its memory.
package void callMiddleware(Middleware mw, Context ctx, Next next) @trusted
{
    mw(ctx, next);
}

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
