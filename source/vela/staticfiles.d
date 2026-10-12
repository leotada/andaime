/// Arquivos estáticos: `app.serveStatic("/assets", "./public");`
///
/// - só GET/HEAD; `/assets/css/app.css` serve `./public/css/app.css`;
/// - `/assets/` (ou uma pasta) serve o `index` configurado (padrão index.html);
/// - proteção contra path traversal: `..`, `\`, NUL, segmentos que começam com
///   ponto (.env, .git) e links simbólicos que saem da pasta raiz são recusados (404);
/// - ETag fraco (tamanho + mtime) com 304 para `If-None-Match`, `Last-Modified`,
///   `Cache-Control` configurável e `Content-Type` pela extensão;
/// - o arquivo é lido para a memória da resposta; arquivos grandes são lidos numa
///   thread do pool (`offload`) para não segurar o worker.
module vela.staticfiles;

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
    string index = "index.html"; /// "" desliga o index de pastas
    size_t maxFileBytes = 16 << 20; /// maior que isso: 413
    size_t offloadAbove = 256 << 10; /// leitura de arquivos maiores vai para o pool de threads
}

/// Serve `dir` em `urlPrefix` ("" = raiz do site). Chame na montagem do app.
void serveStatic(R)(R target, string urlPrefix, string dir, StaticConfig cfg = StaticConfig.init)
    if (is(R == App) || is(R == Group))
{
    auto root = realPath(dir);
    if (root is null)
        throw new Exception("vela: a pasta de estáticos não existe: " ~ dir);
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
            throw new HttpError(404, "não encontrado");
        serve(ctx, rel);
    }

    /// Resolve links simbólicos e só abre se o caminho resolved ficar dentro da pasta raiz.
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
            throw new HttpError(404, "não encontrado");

        string path = root;
        if (rel.length)
            path = root ~ "/" ~ rel.idup;
        string found;
        int fd = openInside(path, found);
        if (fd < 0)
            throw new HttpError(404, "não encontrado");
        scope (exit)
            close(fd);

        stat_t st;
        if (fstat(fd, &st) != 0)
            throw new HttpError(404, "não encontrado");
        if (S_ISDIR(st.st_mode))
        {
            if (cfg.index.length == 0)
                throw new HttpError(404, "não encontrado");
            close(fd);
            path = found ~ "/" ~ cfg.index;
            fd = openInside(path, found);
            if (fd < 0 || fstat(fd, &st) != 0)
                throw new HttpError(404, "não encontrado");
        }
        if (!S_ISREG(st.st_mode))
            throw new HttpError(404, "não encontrado");
        if (st.st_size > cfg.maxFileBytes)
            throw new HttpError(413, "arquivo grande demais");

        immutable size = cast(size_t) st.st_size;
        immutable mtime = cast(long) st.st_mtime;

        // ETag fraco: W/"<tamanho em hex>-<mtime em hex>"
        auto etag = ctx.scratch(48);
        size_t n = 0;
        n += put(etag[n .. $], `W/"`);
        n += putHex(etag[n .. $], size);
        etag[n++] = '-';
        n += putHex(etag[n .. $], cast(ulong) mtime);
        etag[n++] = '"';
        auto etagv = etag[0 .. n];

        auto lm = ctx.scratch(29);
        formatHttpDate(cast(long) mtime, *cast(char[29]*) lm.ptr);

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
            throw new Exception("vela: arquivo mudou durante a leitura: " ~ path);
        ctx.response.body.commit(got);
    }
}

// ------------------------------------------------------------ auxiliares

/// Caminho relativo seguro: sem "..", sem barra invertida, sem NUL, sem segmentos ocultos.
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

private int openChecked(string resolved)
{
    auto z = resolved ~ '\0';
    for (;;)
    {
        int fd = open(z.ptr, O_RDONLY | O_CLOEXEC);
        if (fd >= 0 || errno != EINTR)
            return fd;
    }
}

string realPath(string path)
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

/// `If-None-Match` pode ter vários valores separados por vírgula, ou `*`.
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
