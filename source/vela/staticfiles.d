/// Static files: `app.serveStatic("/assets", "./public");`
///
/// - GET/HEAD only; `/assets/css/app.css` serves `./public/css/app.css`;
/// - `/assets/` (or a folder) serves the configured `index` (default index.html);
/// - path traversal protection: `..`, `\`, NUL, segments starting with a
///   dot (.env, .git) and symlinks that leave the root folder are refused (404);
/// - weak ETag (size + mtime) with 304 for `If-None-Match`, `Last-Modified`,
///   configurable `Cache-Control` and `Content-Type` by extension;
/// - small files are read into the response memory; files above `offloadAbove` (256 KiB) are streamed in 64 KiB pieces
///   read on a pool thread (`offload`), with a Content-Length, so memory does not grow with the file and a slow client
///   only makes the write wait.
module vela.staticfiles;

@safe:

import core.stdc.errno : errno, EINTR;
import core.stdc.stdlib : free;

version (linux)
{
    import core.sys.posix.fcntl : open, O_RDONLY, O_CLOEXEC;
    import core.sys.posix.sys.stat : fstat, stat_t, S_ISDIR, S_ISREG, mode_t;
    import core.sys.posix.unistd : close, read;
}
else version (Posix)
{
    import core.sys.posix.fcntl : open, O_RDONLY;
    enum O_CLOEXEC = 0x1000000;
    import core.sys.posix.sys.stat : fstat, stat_t, S_ISDIR, S_ISREG, mode_t;
    import core.sys.posix.unistd : close, read;
}
else version (Windows)
{
    import core.sys.windows.stat : fstat, struct_stat, S_ISDIR, S_ISREG;
    alias stat_t = struct_stat;
    alias mode_t = ushort;
    enum O_RDONLY = 0x0000;
    enum O_CLOEXEC = 0;
    extern (C) nothrow @nogc
    {
        int _open(const(char)*, int, ...);
        int _close(int);
        int _read(int, void*, uint);
    }
    alias open = _open;
    alias close = _close;
    alias read = _read;
}

import vela.http.types : Method, equalsIgnoreCase;
import vela.http.date : formatHttpDate;
import vela.web.application : App, Group;
import vela.web.context : Context;
import vela.web.stream : Stream, StreamWriter, runStream;
import vela.web.params : HttpError;
import vela.web.convert : percentDecode;
import vela.engine.offload : offload;

struct StaticConfig
{
    string cacheControl = "public, max-age=3600";
    string index = "index.html"; /// "" turns off the folder index
    size_t maxFileBytes = 1 << 30; /// larger than this: 413 (a safety cap: big files are streamed, memory does not grow with them)
    size_t offloadAbove = 256 << 10; /// larger files are streamed in `chunkBytes` pieces, each read on the thread pool
    size_t chunkBytes = 64 << 10;
}

/// Serves `dir` at `urlPrefix` ("" = site root). Call it while assembling the app.
void serveStatic(R)(R target, string urlPrefix, string dir, StaticConfig cfg = StaticConfig.init)
    if (is(R == App) || is(R == Group))
{
    auto root = realPath(dir);
    if (root is null)
        throw new Exception("vela: the static files folder does not exist: " ~ dir);
    auto srv = new StaticServer(root, cfg);
    target.register(Method.GET, urlPrefix ~ "/{*path}", &srv.serveWildcard);
    target.register(Method.GET, urlPrefix.length ? urlPrefix : "/", &srv.serveIndex);
}

private final class StaticServer
{
    string root;
    StaticConfig cfg;

    this(string root, StaticConfig cfg)
    {
        this.root = root;
        this.cfg = cfg;
    }

    void serveIndex(Context ctx)
    {
        serve(ctx, "");
    }

    void serveWildcard(Context ctx)
    {
        const(char)[] rel;
        if (!percentDecode(ctx.params[0], false, rel))
            throw new HttpError(404, "not found");
        serve(ctx, rel);
    }

    /// Resolves symlinks and only opens if the resolved path stays inside the root folder.
    private int openInside(string path, out string found)
    {
        auto resolved = realPath(path);
        if (resolved is null)
            return -1;
        if (resolved != root && !(resolved.length > root.length && resolved[0 .. root.length] == root && resolved[root.length] == '/'))
            return -1;
        found = resolved;
        return openChecked(resolved);
    }

    private void serve(Context ctx, const(char)[] rel)
    {
        if (!safeRelative(rel))
            throw new HttpError(404, "not found");

        string path = root;
        if (rel.length)
            path = root ~ "/" ~ rel.idup;
        string found;
        int fd = openInside(path, found);
        if (fd < 0)
            throw new HttpError(404, "not found");
        scope (exit)
            close(fd);

        stat_t st;
        if (!statFd(fd, st))
            throw new HttpError(404, "not found");
        if (isDirMode(st.st_mode))
        {
            if (cfg.index.length == 0)
                throw new HttpError(404, "not found");
            close(fd);
            path = found ~ "/" ~ cfg.index;
            fd = openInside(path, found);
            if (fd < 0 || !statFd(fd, st))
                throw new HttpError(404, "not found");
        }
        if (!isRegMode(st.st_mode))
            throw new HttpError(404, "not found");
        if (st.st_size > cfg.maxFileBytes)
            throw new HttpError(413, "file too large");

        immutable size = cast(size_t) st.st_size;
        immutable mtime = cast(long) st.st_mtime;

        // weak ETag: W/"<size in hex>-<mtime in hex>"
        auto etag = ctx.scratch(48);
        size_t n = 0;
        n += put(etag[n .. $], `W/"`);
        n += putHex(etag[n .. $], size);
        etag[n++] = '-';
        n += putHex(etag[n .. $], cast(ulong) mtime);
        etag[n++] = '"';
        auto etagv = etag[0 .. n];

        auto lm = ctx.scratch(29);
        // @trusted: `lm` has exactly 29 bytes (scratch(29)), the size of the fixed array
        () @trusted { formatHttpDate(cast(long) mtime, *cast(char[29]*) lm.ptr); }();

        ctx.setHeader("ETag", etagv);
        ctx.setHeader("Last-Modified", lm);
        if (cfg.cacheControl.length)
            ctx.setHeader("Cache-Control", cfg.cacheControl);

        auto inm = ctx.request.header("If-None-Match");
        if (inm.length && matchesEtag(inm, etagv))
        {
            ctx.response.status = 304;
            ctx.response.contentType = null;
            return;
        }

        ctx.response.status = 200;
        ctx.response.contentType = contentTypeFor(path);
        ctx.response.body.clear();
        if (size > cfg.offloadAbove)
        {
            // A big file is sent in pieces, each read on a pool thread: memory does not grow with the file, a slow
            // client just makes `write` wait, and the worker keeps serving others meanwhile.
            immutable f = fd;
            immutable chunk = cfg.chunkBytes;
            immutable name = path;
            auto body_ = Stream(ctx.response.contentType, (scope StreamWriter w) @system {
                auto buf = new char[chunk];
                size_t left = size;
                while (left)
                {
                    auto piece = buf[0 .. left < chunk ? left : chunk];
                    immutable got = offload(() => readFully(f, piece));
                    if (got != piece.length)
                        throw new Exception("vela: file changed while being read: " ~ name);
                    w.write(piece);
                    left -= got;
                }
            }, cast(long) size);
            runStream(ctx, body_); // `fd` stays open until serve() returns, i.e. until the last byte was written
            return;
        }
        auto dest = ctx.response.body.writable(size);
        immutable got = readFully(fd, dest);
        if (got != size)
            throw new Exception("vela: file changed while being read: " ~ path);
        ctx.response.body.commit(got);
    }
}

// ------------------------------------------------------------ helpers

/// Safe relative path: no "..", no backslash, no NUL, no hidden segments.
bool safeRelative(scope const(char)[] rel) pure nothrow @nogc @safe
{
    size_t i = 0;
    while (i <= rel.length)
    {
        size_t j = i;
        while (j < rel.length && rel[j] != '/')
            j++;
        auto seg = rel[i .. j];
        if (seg.length && seg[0] == '.')
            return false; // "..", ".", ".env", ".git"
        foreach (char c; seg)
            if (c == 0 || c == '\\' || c < ' ')
                return false;
        i = j + 1;
    }
    return true;
}

/// @trusted: `z` is a NUL-terminated copy that outlives the call.
private int openChecked(string resolved) @trusted
{
    auto z = resolved ~ '\0';
    for (;;)
    {
        int fd = open(z.ptr, O_RDONLY | O_CLOEXEC);
        if (fd >= 0 || errno != EINTR)
            return fd;
    }
}

/// @trusted: the resolved path is copied before returning.
string realPath(string path) @trusted
{
    version (Posix)
    {
        import core.sys.posix.stdlib : realpath;
        import core.stdc.string : strlen;

        auto z = path ~ '\0';
        char* r = realpath(z.ptr, null);
        if (r is null)
            return null;
        scope (exit)
            free(r);
        return r[0 .. strlen(r)].idup;
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : GetFullPathNameA;
        import core.stdc.string : strlen;

        auto z = path ~ '\0';
        char[1024] buf;
        auto len = GetFullPathNameA(z.ptr, cast(uint) buf.length, buf.ptr, null);
        if (len == 0 || len >= buf.length)
            return null;
        foreach (ref c; buf[0 .. len])
            if (c == '\\')
                c = '/';
        return buf[0 .. len].idup;
    }
}

/// @trusted: fstat writes only into `st`, which is a live local.
private bool statFd(int fd, out stat_t st) @trusted nothrow @nogc => fstat(fd, &st) == 0;

// Older druntime declares S_ISDIR/S_ISREG @system (and impure). Sound: each is a bit test on an integer.
private bool isDirMode(mode_t m) @trusted nothrow @nogc => S_ISDIR(m) != 0;
private bool isRegMode(mode_t m) @trusted nothrow @nogc => S_ISREG(m) != 0;

private size_t readFully(int fd, char[] dest) nothrow @nogc @trusted
{
    size_t got;
    while (got < dest.length)
    {
        version (Windows)
            auto n = read(fd, dest.ptr + got, cast(uint)(dest.length - got > uint.max ? uint.max : dest.length - got));
        else
            auto n = read(fd, dest.ptr + got, dest.length - got);
        if (n > 0)
            got += n;
        else if (n == 0)
            break;
        else if (errno != EINTR)
            break;
    }
    return got;
}

private size_t put(char[] dst, string s) pure nothrow @nogc @safe
{
    dst[0 .. s.length] = s;
    return s.length;
}

private size_t putHex(char[] dst, ulong v) pure nothrow @nogc @safe
{
    char[16] t;
    size_t n = t.length;
    do
    {
        t[--n] = "0123456789abcdef"[v & 15];
        v >>= 4;
    }
    while (v);
    immutable len = t.length - n;
    dst[0 .. len] = t[n .. $];
    return len;
}

/// `If-None-Match` may hold several comma-separated values, or `*`.
private bool matchesEtag(scope const(char)[] header, scope const(char)[] etag) pure nothrow @nogc @safe
{
    size_t i = 0;
    while (i < header.length)
    {
        while (i < header.length && (header[i] == ' ' || header[i] == ','))
            i++;
        size_t j = i;
        while (j < header.length && header[j] != ',')
            j++;
        size_t e = j;
        while (e > i && header[e - 1] == ' ')
            e--;
        auto tag = header[i .. e];
        if (tag == "*" || tag == etag)
            return true;
        i = j + 1;
    }
    return false;
}

string contentTypeFor(scope const(char)[] path) pure nothrow @nogc @safe
{
    size_t dot = path.length;
    foreach_reverse (i, c; path)
    {
        if (c == '/')
            break;
        if (c == '.')
        {
            dot = i;
            break;
        }
    }
    if (dot == path.length)
        return "application/octet-stream";
    auto ext = path[dot + 1 .. $];
    foreach (ref e; table)
        if (equalsIgnoreCase(ext, e[0]))
            return e[1];
    return "application/octet-stream";
}

private immutable string[2][] table = [
    ["html", "text/html; charset=utf-8"], ["htm", "text/html; charset=utf-8"],
    ["css", "text/css; charset=utf-8"], ["js", "text/javascript; charset=utf-8"],
    ["mjs", "text/javascript; charset=utf-8"], ["json", "application/json"],
    ["map", "application/json"], ["txt", "text/plain; charset=utf-8"],
    ["md", "text/markdown; charset=utf-8"], ["csv", "text/csv; charset=utf-8"],
    ["xml", "application/xml"], ["svg", "image/svg+xml"], ["png", "image/png"],
    ["jpg", "image/jpeg"], ["jpeg", "image/jpeg"], ["gif", "image/gif"],
    ["webp", "image/webp"], ["avif", "image/avif"], ["ico", "image/x-icon"],
    ["woff", "font/woff"], ["woff2", "font/woff2"], ["ttf", "font/ttf"],
    ["otf", "font/otf"], ["pdf", "application/pdf"], ["wasm", "application/wasm"],
    ["mp4", "video/mp4"], ["webm", "video/webm"], ["mp3", "audio/mpeg"],
    ["zip", "application/zip"], ["gz", "application/gzip"],
];

unittest
{
    assert(safeRelative("") && safeRelative("css/app.css") && safeRelative("a/b/"));
    assert(!safeRelative("../etc/passwd") && !safeRelative("a/../b") && !safeRelative(".env"));
    assert(!safeRelative("a/.git/config") && !safeRelative("a\\b") && !safeRelative("a\0b"));
    assert(contentTypeFor("/x/app.CSS") == "text/css; charset=utf-8");
    assert(contentTypeFor("/x.d/noext") == "application/octet-stream");
    assert(matchesEtag(`"a", W/"b"`, `W/"b"`) && matchesEtag("*", "x") && !matchesEtag(`"a"`, `"b"`));
}
