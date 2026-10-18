/// CORS (Cross-Origin Resource Sharing) middleware.
///
///     app.use(cors(CorsConfig(["https://app.example.com"])));
///     app.use(cors(CorsConfig(["*"])));                   // any origin, no cookies
///
/// Runs before routing (use `app.use`), so it also answers the preflight
/// `OPTIONS` of routes that only exist for GET/POST. Without `Origin` on the request, it does nothing.
module andaime.web.cors;

@safe:

import andaime.http.types : Method, equalsIgnoreCase;
import andaime.web.context;

struct CorsConfig
{
    /// Accepted origins ("https://app.example.com"); ["*"] accepts any.
    string[] origins;
    string methods = "GET, HEAD, POST, PUT, PATCH, DELETE";
    /// Headers accepted in the preflight; empty = returns what the browser asked for.
    string allowHeaders;
    /// Response headers that JavaScript may read.
    string exposeHeaders;
    /// Allows cookies/Authorization. Incompatible with origin "*": in that case the origin is echoed.
    bool credentials;
    /// How long the browser may cache the preflight result.
    uint maxAgeSeconds = 600;
}

Middleware cors(CorsConfig cfg)
{
    bool any;
    foreach (o; cfg.origins)
        if (o == "*")
            any = true;
    immutable string maxAge = utoa(cfg.maxAgeSeconds);
    // With a fixed `*` (no credentials) every response is the same for every origin. In every other case the answer
    // depends on the Origin header, including "no CORS headers at all" for a missing or disallowed origin: a shared
    // cache must not hand that variant to an allowed origin, so `Vary: Origin` goes on every response.
    immutable bool varyOrigin = !(any && !cfg.credentials);

    return (Context ctx, Next next) {
        if (varyOrigin)
            ctx.addVary("Origin");
        auto origin = ctx.request.header("Origin");
        if (origin is null)
        {
            next();
            return;
        }

        bool allowed = any;
        if (!allowed)
            foreach (o; cfg.origins)
                if (o == origin)
                {
                    allowed = true;
                    break;
                }
        if (!allowed)
        {
            // unknown origin: continue without CORS headers (the browser blocks it by itself)
            next();
            return;
        }

        // with credentials "*" is forbidden by the browser: echo the origin
        if (any && !cfg.credentials)
            ctx.setHeader("Access-Control-Allow-Origin", "*");
        else
            ctx.setHeader("Access-Control-Allow-Origin", origin);
        if (cfg.credentials)
            ctx.setHeader("Access-Control-Allow-Credentials", "true");

        bool preflight = ctx.request.method == Method.OPTIONS
            && ctx.request.header("Access-Control-Request-Method") !is null;
        if (preflight)
        {
            ctx.setHeader("Access-Control-Allow-Methods", cfg.methods);
            ctx.addVary("Access-Control-Request-Method");
            auto wanted = ctx.request.header("Access-Control-Request-Headers");
            if (cfg.allowHeaders.length)
                ctx.setHeader("Access-Control-Allow-Headers", cfg.allowHeaders);
            else if (wanted.length)
            {
                ctx.setHeader("Access-Control-Allow-Headers", wanted);
                ctx.addVary("Access-Control-Request-Headers"); // the answer echoes what the browser asked for
            }
            ctx.setHeader("Access-Control-Max-Age", maxAge);
            ctx.response.status = 204;
            ctx.response.contentType = null;
            ctx.response.body.clear();
            return; // does not continue to routing
        }

        if (cfg.exposeHeaders.length)
            ctx.setHeader("Access-Control-Expose-Headers", cfg.exposeHeaders);
        next();
    };
}

private string utoa(uint v) pure nothrow @safe
{
    char[12] t;
    size_t n = t.length;
    do
    {
        t[--n] = cast(char)('0' + v % 10);
        v /= 10;
    }
    while (v);
    return t[n .. $].idup;
}
