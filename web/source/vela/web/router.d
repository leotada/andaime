/// Routing by a prefix tree of segments (radix over segments).
///
/// The tree is built at startup (microseconds), not at CTFE, so it does not
/// weigh on compilation. Matching does not allocate and is O(depth).
/// Priority per segment: static > `{param}` > `{*rest}`, with
/// backtracking, so `/users/me` and `/users/{id}` coexist.
module vela.web.router;

@safe:

import vela.http.types;
import vela.web.context : PathParams;

enum MatchStatus { found, notFound, methodNotAllowed }

struct MatchResult
{
    MatchStatus status;
    int handler = -1;
    ushort allowed; /// bitmask of methods when the path matches but the method does not
}

/// Route registration error (startup): one-line message.
class RouteError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

private final class Node
{
    string segment;     // literal text, or the parameter name
    Node[] statics;     // literal children (linear search; sort if it grows)
    Node param;         // `{name}` child
    Node catchAll;      // `{*name}` child (always a leaf)
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

/// Segments of a pattern. "/" => []; "/a/" => ["a", ""] (the trailing slash is significant).
private string[] splitPattern(string pattern) @safe pure
{
    if (pattern.length == 0 || pattern[0] != '/')
        throw new RouteError("vela: route '" ~ pattern ~ "' must start with '/'");
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

    /// Registers `pattern` for `method`. Throws RouteError with a clear message.
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
                    throw new RouteError("vela: route '" ~ pattern ~ "' has more than 8 parameters");
                if (name.length && name[0] == '*')
                {
                    if (idx != segs.length - 1)
                        throw new RouteError("vela: in '" ~ pattern ~ "', {" ~ name
                            ~ "} captures the rest of the path and must be the last segment");
                    if (n.catchAll is null)
                        n.catchAll = new Node(name[1 .. $]);
                    n = n.catchAll;
                }
                else
                {
                    if (n.param is null)
                        n.param = new Node(name);
                    n = n.param; // different names at the same position are allowed:
                                 // binding is by position, decided at compile time
                }
            }
            else
            {
                foreach (char c; seg)
                    if (c == '{' || c == '}')
                        throw new RouteError("vela: segment '" ~ seg ~ "' in '" ~ pattern
                            ~ "' mixes text and a parameter; use a whole segment such as {name}");
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
            throw new RouteError("vela: duplicate route: " ~ methodName(method) ~ " " ~ pattern
                ~ " (already registered as " ~ n.patterns[method] ~ ")");
        n.handlers[method] = handlerId;
        n.patterns[method] = pattern;
        routeCount++;
    }

    /// Matches `path` (with leading '/', without query). Fills `params` in pattern order.
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
            h = n.handlers[Method.GET]; // HEAD falls back to GET; the engine discards the body
        if (h >= 0)
        {
            res.handler = h;
            return true;
        }
        res.allowed |= n.mask();
        return false;
    }

    /// `i` = start of the next segment; size_t.max = path consumed.
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

    /// Tree as text, for debugging and snapshot tests.
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
    assert(r.match(Method.GET, "/users/me", pp).handler == 4);           // static wins
    m = r.match(Method.PUT, "/users/me", pp);                              // no PUT on /users/me:
    assert(m.handler == 3 && pp[0] == "me");                               // backtracking to {id}
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
    assert(r.match(Method.GET, "/users/", pp).status == MatchStatus.notFound); // trailing slash is strict

    bool threw;
    try r.add(Method.GET, "/users/{x}", 9);
    catch (RouteError e) { threw = true; assert(e.msg == "vela: duplicate route: GET /users/{x} (already registered as /users/{id})"); }
    assert(threw);
}
