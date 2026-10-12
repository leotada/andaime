/// `App`: registro de rotas, middlewares e o ponto de entrada por requisição.
module vela.web.application;

import vela.http.types;
import vela.web.context;
import vela.web.params : HttpError;
import vela.web.router;
import vela.web.handler_traits : handlerError, dispatch;
import vela.web.json : writeJsonString;
import vela.web.openapi;

/// UDA de rota para métodos de controllers: `@Get("/users/{id}")`.
struct Route
{
    Method method;
    string path;
}

Route Get(string path) => Route(Method.GET, path);
Route Post(string path) => Route(Method.POST, path);
Route Put(string path) => Route(Method.PUT, path);
Route Patch(string path) => Route(Method.PATCH, path);
Route Delete(string path) => Route(Method.DELETE, path);

alias HandlerFn = void delegate(Context);

/// Chamado no lugar do tratamento padrão quando um handler ou middleware lança.
/// Escreva a resposta em `ctx` (`ctx.text(...)`, `ctx.response.status = ...`).
alias ErrorHandler = void delegate(Context ctx, Exception e);

/// Executa os middlewares de um grupo e, no fim, o handler da rota.
private final class Chain
{
    Middleware[] mws;
    HandlerFn handler;

    void run(Context ctx, size_t i)
    {
        if (i < mws.length)
            mws[i](ctx, Next(&run, i + 1, ctx));
        else
            handler(ctx);
    }

    void entry(Context ctx)
    {
        run(ctx, 0);
    }
}

/// Conjunto de rotas com prefixo e middlewares próprios:
///
///     auto api = app.group("/api/v1");
///     api.use(&exigeLogin);
///     api.get!("/users/{id}", getUser);        // GET /api/v1/users/{id}, com exigeLogin
///
/// Um middleware vale para as rotas registradas DEPOIS do `use` (como no Express).
/// O prefixo é texto puro: sem `{param}` (o binding por nome é decidido em compilação).
final class Group
{
    private App app;
    private string prefix;
    private Middleware[] mws;

    private this(App app, string prefix, Middleware[] inherited)
    {
        this.app = app;
        this.prefix = prefix;
        this.mws = inherited;
    }

    void use(Middleware mw)
    {
        mws ~= mw;
    }

    void use(void function(Context, Next) mw)
    {
        mws ~= (Context c, Next n) => mw(c, n);
    }

    /// Subgrupo: herda o prefixo e os middlewares atuais.
    Group group(string sub)
    {
        return new Group(app, prefix ~ checkPrefix(sub), mws.dup);
    }

    void register(Method method, string path, HandlerFn h, OpDescribe describe = null)
    {
        auto full = (path == "/" && prefix.length) ? prefix : prefix ~ path;
        if (mws.length == 0)
            return app.register(method, full, h, describe);
        auto c = new Chain;
        c.mws = mws.dup;
        c.handler = h;
        app.register(method, full, &c.entry, describe);
    }
}

private string checkPrefix(string prefix) pure
{
    if (prefix.length && prefix[0] != '/')
        throw new RouteError("vela: o prefixo do grupo '" ~ prefix ~ "' deve começar com '/'");
    if (prefix.length && prefix[$ - 1] == '/')
        throw new RouteError("vela: o prefixo do grupo '" ~ prefix ~ "' não deve terminar com '/'");
    foreach (char c; prefix)
        if (c == '{' || c == '}')
            throw new RouteError("vela: o prefixo do grupo '" ~ prefix ~ "' não pode ter {parâmetros}; "
                ~ "ponha os parâmetros nas rotas do grupo");
    return prefix;
}

final class App
{
    private Router router;
    private HandlerFn[] handlers;
    private Middleware[] middlewares;
    private ErrorHandler errorHandler;
    private HandlerFn notFoundHandler;
    private OpRecord[] ops;

    /// Se a rota não existe mas existe com/sem a barra final, responde 308 para ela.
    bool redirectTrailingSlash;

    this()
    {
        router = new Router;
    }

    // ---- middlewares (ordem de registro = de fora para dentro)

    void use(Middleware mw)
    {
        middlewares ~= mw;
    }

    void use(void function(Context, Next) mw)
    {
        middlewares ~= (Context c, Next n) => mw(c, n);
    }

    /// Cria um grupo de rotas com prefixo e middlewares próprios.
    Group group(string prefix)
    {
        return new Group(this, checkPrefix(prefix), null);
    }

    /// Trata qualquer exceção lançada por handlers e middlewares (incluindo `HttpError`).
    /// Exceções que não são `HttpError` continuam sendo registradas no log antes.
    void onError(ErrorHandler h)
    {
        errorHandler = h;
    }

    /// Resposta para rotas inexistentes (substitui o 404 em JSON padrão).
    void onNotFound(HandlerFn h)
    {
        notFoundHandler = h;
    }

    /// Registra um handler já gerado. As funções `get`/`post`/... abaixo
    /// validam a assinatura em compilação e chamam isto.
    void register(Method method, string path, HandlerFn h, OpDescribe describe = null)
    {
        handlers ~= h;
        router.add(method, path, cast(int)(handlers.length - 1));
        ops ~= OpRecord(method, path, describe);
    }

    /// Publica `/openapi.json` (e a página `/docs`) gerados das assinaturas dos
    /// handlers registrados ATÉ aqui. Chame depois de registrar as rotas.
    void serveOpenApi(OpenApiInfo info = OpenApiInfo.init)
    {
        auto records = ops.dup;
        string cached;
        if (info.jsonPath.length)
            register(Method.GET, info.jsonPath, delegate(Context c) {
                if (cached is null)
                    cached = buildOpenApi(records, info);
                c.response.contentType = "application/json";
                c.response.body.put(cached);
            });
        if (info.docsPath.length)
        {
            auto html = docsHtml(info.jsonPath, info.title);
            register(Method.GET, info.docsPath, delegate(Context c) {
                c.response.contentType = "text/html; charset=utf-8";
                c.response.body.put(html);
            });
        }
    }

    /// Registra todos os métodos de `controller` anotados com @Get/@Post/...
    /// Use para handlers com estado (repositórios, conexões, config).
    void mount(C, string file = __FILE__, size_t line = __LINE__)(C controller) if (is(C == class))
    {
        static foreach (member; __traits(allMembers, C))
        {
            static if (__traits(compiles, __traits(getOverloads, C, member)))
            {
                static foreach (ov; __traits(getOverloads, C, member))
                {
                    static foreach (attr; __traits(getAttributes, ov))
                    {
                        static if (is(typeof(attr) == Route))
                        {{
                            enum err = handlerError!(attr.method, attr.path, ov, file, line);
                            static if (err.length)
                                static assert(0, err);
                            else
                                register(attr.method, attr.path, delegate(Context c) { dispatch!(attr.method, attr.path, ov)(c, controller); },
                                    delegate string(ref Components cs, string pat) @safe { return describeOperation!(attr.method, attr.path, ov)(cs, pat); });
                        }}
                    }
                }
            }
        }
    }

    /// Árvore de rotas em texto (depuração).
    string routes() const => router.dump();

    // ---- execução

    /// Processa a requisição já carregada em `ctx`. Nunca lança.
    void handle(Context ctx)
    {
        try
            runFrom(ctx, 0);
        catch (Exception e)
            fail(ctx, e);
    }

    private void fail(Context ctx, Exception e)
    {
        if (errorHandler is null)
        {
            if (auto he = cast(HttpError) e)
                renderError(ctx, he.status, he.msg);
            else
                internalError(ctx, e);
            return;
        }
        if (cast(HttpError) e is null)
            logError(ctx, e);
        ctx.response.status = 500;
        ctx.response.contentType = null;
        ctx.response.body.clear();
        try
            errorHandler(ctx, e);
        catch (Exception e2) // o handler de erro também falhou: não há mais o que fazer
        {
            logError(ctx, e2);
            renderError(ctx, 500, "erro interno");
        }
    }

    private void runFrom(Context ctx, size_t i)
    {
        if (i < middlewares.length)
            middlewares[i](ctx, Next(&runFrom, i + 1, ctx));
        else
            endpoint(ctx);
    }

    private void endpoint(Context ctx)
    {
        auto r = router.match(ctx.request.method, ctx.request.path, ctx.params);
        final switch (r.status)
        {
            case MatchStatus.found:
                try
                    handlers[r.handler](ctx);
                catch (Exception e) // capturado aqui para os middlewares verem o status final
                    fail(ctx, e);
                break;
            case MatchStatus.notFound:
                if (redirectTrailingSlash && tryTrailingSlash(ctx))
                    break;
                if (notFoundHandler !is null)
                {
                    try
                        notFoundHandler(ctx);
                    catch (Exception e)
                        fail(ctx, e);
                }
                else
                    renderError(ctx, 404, "não encontrado");
                break;
            case MatchStatus.methodNotAllowed:
                ctx.setHeader("Allow", allowList(ctx, r.allowed));
                renderError(ctx, 405, "método não permitido");
                break;
        }
    }

    /// "/a/b/" <-> "/a/b": se o outro formato existe, redireciona (308 mantém método e corpo).
    private bool tryTrailingSlash(Context ctx)
    {
        auto p = ctx.request.path;
        if (p.length == 0)
            return false;
        PathParams scratch;
        immutable stripped = p.length > 1 && p[$ - 1] == '/';
        auto alt = stripped ? p[0 .. $ - 1] : p;
        // para "adicionar", monta no scratch do contexto (sem GC no caso comum)
        char[] buf;
        if (!stripped)
        {
            buf = ctx.scratch(p.length + 1 + (ctx.request.query.length ? ctx.request.query.length + 1 : 0));
            buf[0 .. p.length] = p;
            buf[p.length] = '/';
            alt = buf[0 .. p.length + 1];
        }
        if (router.match(ctx.request.method, alt, scratch).status != MatchStatus.found)
            return false;

        char[] loc;
        if (stripped)
            loc = ctx.scratch(alt.length + (ctx.request.query.length ? ctx.request.query.length + 1 : 0));
        else
            loc = buf; // já tem a folga da query
        size_t n = alt.length;
        if (stripped)
            loc[0 .. n] = alt;
        if (ctx.request.query.length)
        {
            loc[n++] = '?';
            loc[n .. n + ctx.request.query.length] = ctx.request.query;
            n += ctx.request.query.length;
        }
        ctx.response.status = 308;
        ctx.response.contentType = null;
        ctx.response.body.clear();
        ctx.setHeader("Location", loc[0 .. n]);
        return true;
    }

    private static const(char)[] allowList(Context ctx, ushort mask) nothrow @nogc @safe
    {
        size_t n = 0;
        foreach (i; 0 .. methodCount)
        {
            if (!(mask & (1 << i)))
                continue;
            auto name = methodName(cast(Method) i);
            if (n)
            {
                ctx.allowBuf[n .. n + 2] = ", ";
                n += 2;
            }
            ctx.allowBuf[n .. n + name.length] = name;
            n += name.length;
        }
        return ctx.allowBuf[0 .. n];
    }

    private static void renderError(Context ctx, int status, scope const(char)[] msg)
    {
        ctx.response.status = status;
        ctx.response.contentType = "application/json";
        ctx.response.body.clear();
        ctx.response.body.put(`{"detail":`);
        writeJsonString(ctx.response.body, msg);
        ctx.response.body.put('}');
    }

    private static void internalError(Context ctx, Exception e)
    {
        logError(ctx, e);
        renderError(ctx, 500, "erro interno");
    }

    private static void logError(Context ctx, Exception e) nothrow
    {
        import core.stdc.stdio : fprintf, stderr;

        // detalhes só no log, nunca na resposta
        fprintf(stderr, "vela: erro em %.*s %.*s: %.*s (%.*s:%d)\n",
            cast(int) methodName(ctx.request.method).length, methodName(ctx.request.method).ptr,
            cast(int) ctx.request.path.length, ctx.request.path.ptr,
            cast(int) e.msg.length, e.msg.ptr, cast(int) e.file.length, e.file.ptr, cast(int) e.line);
    }
}

// ---- registro de rotas: funções livres chamadas via UFCS (`app.get!(...)`).
// Livres, e não métodos de App, de propósito: assim um lambda local que
// captura dependências (`(long id) => repo.find(id)`) vira um closure comum,
// sem o "dual-context" que o D deprecou. A validação roda aqui, no ponto de
// chamada do usuário, e o erro de compilação tem só duas linhas.
// Valem para `App` e para `Group` (`api.get!("/x", fn)`).

private enum isRouteTarget(R) = is(R == App) || is(R == Group);

void get(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.GET, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.GET, path, delegate(Context c) { dispatch!(Method.GET, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.GET, path, fn)(cs, pat); });
}

void post(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.POST, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.POST, path, delegate(Context c) { dispatch!(Method.POST, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.POST, path, fn)(cs, pat); });
}

void put(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.PUT, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.PUT, path, delegate(Context c) { dispatch!(Method.PUT, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.PUT, path, fn)(cs, pat); });
}

void patch(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.PATCH, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.PATCH, path, delegate(Context c) { dispatch!(Method.PATCH, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.PATCH, path, fn)(cs, pat); });
}

void del(string path, alias fn, string file = __FILE__, size_t line = __LINE__, R)(R app) if (isRouteTarget!R)
{
    enum err = handlerError!(Method.DELETE, path, fn, file, line);
    static if (err.length) static assert(0, err);
    else app.register(Method.DELETE, path, delegate(Context c) { dispatch!(Method.DELETE, path, fn)(c); },
        delegate string(ref Components cs, string pat) @safe { return describeOperation!(Method.DELETE, path, fn)(cs, pat); });
}
