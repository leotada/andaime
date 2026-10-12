/// Middleware de CORS (Cross-Origin Resource Sharing).
///
///     app.use(cors(CorsConfig(["https://app.exemplo.com"])));
///     app.use(cors(CorsConfig(["*"])));                   // qualquer origem, sem cookies
///
/// Roda antes do roteamento (use `app.use`), então responde também ao preflight
/// `OPTIONS` de rotas que só existem para GET/POST. Sem `Origin` na requisição, não faz nada.
module vela.web.cors;

import vela.http.types : Method, equalsIgnoreCase;
import vela.web.context;

struct CorsConfig
{
    /// Origens aceitas ("https://app.exemplo.com"); ["*"] aceita qualquer uma.
    string[] origins;
    string methods = "GET, HEAD, POST, PUT, PATCH, DELETE";
    /// Headers aceitos no preflight; vazio = devolve o que o navegador pediu.
    string allowHeaders;
    /// Headers de resposta que o JavaScript pode ler.
    string exposeHeaders;
    /// Permite cookies/Authorization. Incompatível com origem "*": nesse caso a origem é ecoada.
    bool credentials;
    /// Quanto o navegador pode guardar o resultado do preflight.
    uint maxAgeSeconds = 600;
}

Middleware cors(CorsConfig cfg)
{
    bool any;
    foreach (o; cfg.origins)
        if (o == "*")
            any = true;
    immutable string maxAge = utoa(cfg.maxAgeSeconds);

    return (Context ctx, Next next) {
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
            // origem desconhecida: segue sem headers CORS (o navegador bloqueia sozinho)
            next();
            return;
        }

        // com credenciais "*" é proibido pelo navegador: ecoa a origem
        if (any && !cfg.credentials)
            ctx.setHeader("Access-Control-Allow-Origin", "*");
        else
        {
            ctx.setHeader("Access-Control-Allow-Origin", origin);
            ctx.setHeader("Vary", "Origin");
        }
        if (cfg.credentials)
            ctx.setHeader("Access-Control-Allow-Credentials", "true");

        bool preflight = ctx.request.method == Method.OPTIONS
            && ctx.request.header("Access-Control-Request-Method") !is null;
        if (preflight)
        {
            ctx.setHeader("Access-Control-Allow-Methods", cfg.methods);
            auto wanted = ctx.request.header("Access-Control-Request-Headers");
            if (cfg.allowHeaders.length)
                ctx.setHeader("Access-Control-Allow-Headers", cfg.allowHeaders);
            else if (wanted.length)
                ctx.setHeader("Access-Control-Allow-Headers", wanted);
            ctx.setHeader("Access-Control-Max-Age", maxAge);
            ctx.response.status = 204;
            ctx.response.contentType = null;
            ctx.response.body.clear();
            return; // não segue para o roteamento
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
