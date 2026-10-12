/// Roteamento por árvore de prefixos de segmentos (radix sobre segmentos).
///
/// A árvore é montada no startup (microssegundos), não em CTFE, para não
/// pesar na compilação. O casamento não aloca e é O(profundidade).
/// Prioridade por segmento: estático > `{param}` > `{*resto}`, com
/// backtracking, então `/users/me` e `/users/{id}` convivem.
module vela.web.router;

import vela.http.types;
import vela.web.context : PathParams;

enum MatchStatus { found, notFound, methodNotAllowed }

struct MatchResult
{
    MatchStatus status;
    int handler = -1;
    ushort allowed; /// bitmask de métodos quando o path casa mas o método não
}

/// Erro de registro de rota (startup): mensagem de uma linha.
class RouteError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

private final class Node
{
    string segment;     // texto literal, ou nome do parâmetro
    Node[] statics;     // filhos literais (busca linear; ordenar se crescer)
    Node param;         // filho `{nome}`
    Node catchAll;      // filho `{*nome}` (sempre folha)
    int[methodCount] handlers = -1;
    string[methodCount] patterns;

    this(string segment) @safe pure nothrow
    {
        this.segment = segment;
    }

    ushort mask() const pure nothrow @nogc @safe
    {
        ushort m;
        foreach (i, h; handlers)
            if (h >= 0)
                m |= cast(ushort)(1 << i);
        return m;
    }
}

/// Segmentos de um padrão. "/" => []; "/a/" => ["a", ""] (barra final é significativa).
private string[] splitPattern(string pattern) @safe pure
{
    if (pattern.length == 0 || pattern[0] != '/')
        throw new RouteError("vela: a rota '" ~ pattern ~ "' deve começar com '/'");
    string[] segs;
    if (pattern == "/")
        return segs;
    size_t st = 1;
    foreach (i; 1 .. pattern.length + 1)
        if (i == pattern.length || pattern[i] == '/')
        {
            segs ~= pattern[st .. i];
            st = i + 1;
        }
    return segs;
}

final class Router
{
    private Node root;
    private size_t routeCount;

    this() @safe pure nothrow
    {
        root = new Node("");
    }

    /// Registra `pattern` para `method`. Lança RouteError com mensagem clara.
    void add(Method method, string pattern, int handlerId) @safe pure
    {
        auto segs = splitPattern(pattern);
        Node n = root;
        size_t params = 0;
        foreach (idx, seg; segs)
        {
            if (seg.length >= 2 && seg[0] == '{' && seg[$ - 1] == '}')
            {
                auto name = seg[1 .. $ - 1];
                params++;
                if (params > PathParams.max)
                    throw new RouteError("vela: a rota '" ~ pattern ~ "' tem mais de 8 parâmetros");
                if (name.length && name[0] == '*')
                {
                    if (idx != segs.length - 1)
                        throw new RouteError("vela: em '" ~ pattern ~ "', {" ~ name
                            ~ "} captura o resto do caminho e precisa ser o último segmento");
                    if (n.catchAll is null)
                        n.catchAll = new Node(name[1 .. $]);
                    n = n.catchAll;
                }
                else
                {
                    if (n.param is null)
                        n.param = new Node(name);
                    n = n.param; // nomes diferentes na mesma posição são permitidos:
                                 // o binding é por posição, decidido em compilação
                }
            }
            else
            {
                foreach (char c; seg)
                    if (c == '{' || c == '}')
                        throw new RouteError("vela: segmento '" ~ seg ~ "' em '" ~ pattern
                            ~ "' mistura texto e parâmetro; use um segmento inteiro como {nome}");
                Node next;
                foreach (c; n.statics)
                    if (c.segment == seg)
                    {
                        next = c;
                        break;
                    }
                if (next is null)
                {
                    next = new Node(seg);
                    n.statics ~= next;
                }
                n = next;
            }
        }
        if (n.handlers[method] >= 0)
            throw new RouteError("vela: rota duplicada: " ~ methodName(method) ~ " " ~ pattern
                ~ " (já registrada como " ~ n.patterns[method] ~ ")");
        n.handlers[method] = handlerId;
        n.patterns[method] = pattern;
        routeCount++;
    }

    /// Casa `path` (com '/' inicial, sem query). Preenche `params` na ordem do padrão.
    MatchResult match(Method method, scope const(char)[] path, ref PathParams params) const nothrow @nogc @safe
    {
        MatchResult res;
        params.count = 0;
        if (path.length == 0 || path[0] != '/')
        {
            res.status = MatchStatus.notFound;
            return res;
        }
        immutable size_t start = path.length > 1 ? 1 : size_t.max;
        if (walk(root, path, start, method, params, res))
            res.status = MatchStatus.found;
        else
            res.status = res.allowed ? MatchStatus.methodNotAllowed : MatchStatus.notFound;
        return res;
    }

    private static bool leaf(const Node n, Method m, ref MatchResult res) nothrow @nogc @safe
    {
        int h = n.handlers[m];
        if (h < 0 && m == Method.HEAD)
            h = n.handlers[Method.GET]; // HEAD cai no GET; o engine descarta o corpo
        if (h >= 0)
        {
            res.handler = h;
            return true;
        }
        res.allowed |= n.mask();
        return false;
    }

    /// `i` = início do próximo segmento; size_t.max = caminho consumido.
    private static bool walk(const Node n, scope const(char)[] path, size_t i, Method m,
        ref PathParams pp, ref MatchResult res) nothrow @nogc @trusted
    {
        if (i == size_t.max)
            return leaf(n, m, res);

        size_t j = i;
        while (j < path.length && path[j] != '/')
            j++;
        const seg = path[i .. j];
        immutable size_t next = j < path.length ? j + 1 : size_t.max;

        foreach (c; n.statics)
            if (c.segment == seg)
            {
                if (walk(c, path, next, m, pp, res))
                    return true;
                break;
            }
        if (n.param !is null && seg.length)
        {
            pp.push(seg);
            if (walk(n.param, path, next, m, pp, res))
                return true;
            pp.pop();
        }
        if (n.catchAll !is null)
        {
            pp.push(path[i .. $]);
            if (leaf(n.catchAll, m, res))
                return true;
            pp.pop();
        }
        return false;
    }

    /// Árvore em texto, para depuração e para testes de snapshot.
    string dump() const @safe
    {
        string o;
        void rec(const Node n, string indent) @safe
        {
            foreach (i, h; n.handlers)
                if (h >= 0)
                    o ~= indent ~ "  " ~ methodName(cast(Method) i) ~ " " ~ n.patterns[i] ~ "\n";
            foreach (c; n.statics)
            {
                o ~= indent ~ "/" ~ c.segment ~ "\n";
                rec(c, indent ~ "  ");
            }
            if (n.param)
            {
                o ~= indent ~ "/{" ~ n.param.segment ~ "}\n";
                rec(n.param, indent ~ "  ");
            }
            if (n.catchAll)
            {
                o ~= indent ~ "/{*" ~ n.catchAll.segment ~ "}\n";
                rec(n.catchAll, indent ~ "  ");
            }
        }

        rec(root, "");
        return o;
    }
}

unittest
{
    auto r = new Router;
    r.add(Method.GET, "/", 0);
    r.add(Method.GET, "/users", 1);
    r.add(Method.GET, "/users/{id}", 2);
    r.add(Method.PUT, "/users/{id}", 3);
    r.add(Method.GET, "/users/me", 4);
    r.add(Method.GET, "/users/{userId}/posts/{postId}", 5);
    r.add(Method.GET, "/static/{*path}", 6);
    r.add(Method.POST, "/users/me", 7);

    PathParams pp;
    auto m = r.match(Method.GET, "/users/42", pp);
    assert(m.status == MatchStatus.found && m.handler == 2 && pp.count == 1 && pp[0] == "42");
    assert(r.match(Method.GET, "/users/me", pp).handler == 4);           // estático vence
    m = r.match(Method.PUT, "/users/me", pp);                              // sem PUT em /users/me:
    assert(m.handler == 3 && pp[0] == "me");                               // backtracking p/ {id}
    m = r.match(Method.GET, "/users/7/posts/9", pp);
    assert(m.handler == 5 && pp.count == 2 && pp[0] == "7" && pp[1] == "9");
    m = r.match(Method.GET, "/static/css/app.css", pp);
    assert(m.handler == 6 && pp[0] == "css/app.css");
    assert(r.match(Method.GET, "/", pp).handler == 0);
    assert(r.match(Method.HEAD, "/users", pp).handler == 1);               // HEAD -> GET
    m = r.match(Method.DELETE, "/users/42", pp);
    assert(m.status == MatchStatus.methodNotAllowed);
    assert(m.allowed == ((1 << Method.GET) | (1 << Method.PUT)));
    assert(r.match(Method.GET, "/nope", pp).status == MatchStatus.notFound);
    assert(r.match(Method.GET, "/users/", pp).status == MatchStatus.notFound); // barra final é estrita

    bool threw;
    try r.add(Method.GET, "/users/{x}", 9);
    catch (RouteError e) { threw = true; assert(e.msg == "vela: rota duplicada: GET /users/{x} (já registrada como /users/{id})"); }
    assert(threw);
}
