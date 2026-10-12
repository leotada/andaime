/// Static files: `app.serveStatic("/assets", "./public");`
///
/// - GET/HEAD only; `/assets/css/app.css` serves `./public/css/app.css`;
/// - `/assets/` (or a folder) serves the configured `index` (default index.html);
/// - path traversal protection: `..`, `\`, NUL, segments starting with a
///   dot (.env, .git) and symlinks that leave the root folder are refused (404);
/// - weak ETag (size + mtime) with 304 for `If-None-Match`, `Last-Modified`,
///   configurable `Cache-Control` and `Content-Type` by extension;
/// - the file is read into the response memory; large files are read on a
///   pool thread (`offload`) so they do not hold the worker.
module vela.staticfiles;

@safe:

import core.stdc.errno : errno, EINTR;
import core.stdc.stdlib : free;
import core.sys.posix.fcntl : open, O_RDONLY, O_CLOEXEC;
import core.sys.posix.sys.stat : fstat, stat_t, S_ISDIR, S_ISREG;
import core.sys.posix.unistd : close, read;

import vela.http.types : Method, equalsIgnoreCase;
import vela.http.date : formatHttpDate;
import vela.web.application : App, Group;
import vela.web.context : Context;
import vela.web.params : HttpError;
import vela.web.convert : percentDecode;
import vela.engine.offload : offload;

struct StaticConfig
{
    string cacheControl = "public, max-age=3600";
    string index = "index.html"; /// "" turns off the folder index
    size_t maxFileBytes = 16 << 20; /// larger than this: 413
    size_t offloadAbove = 256 << 10; /// reading larger files goes to the thread pool
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
        if (S_ISDIR(st.st_mode))
        {
            if (cfg.index.length == 0)
                throw new HttpError(404, "not found");
            close(fd);
            path = found ~ "/" ~ cfg.index;
            fd = openInside(path, found);
            if (fd < 0 || !statFd(fd, st))
                throw new HttpError(404, "not found");
        }
        if (!S_ISREG(st.st_mode))
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
        auto dest = ctx.response.body.writable(size);
        size_t got;
        if (size > cfg.offloadAbove)
        {
            int f = fd;
            got = offload(() => readFully(f, dest));
        }
        else
            got = readFully(fd, dest);
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

/// @trusted: the C string from realpath() is copied and freed before returning.
string realPath(string path) @trusted
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

/// @trusted: fstat writes only into `st`, which is a live local.
private bool statFd(int fd, out stat_t st) @trusted nothrow @nogc => fstat(fd, &st) == 0;

private size_t readFully(int fd, char[] dest) nothrow @nogc @trusted
{
    size_t got;
    while (got < dest.length)
    {
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
