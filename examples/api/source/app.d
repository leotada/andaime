/// API "de verdade" em vela: usuários no Postgres (RDS), cotação vinda de uma API
/// externa, autenticação Bearer, CORS, arquivos estáticos e OpenAPI.
///
/// Variáveis de ambiente:
///   PORT           porta (8080)
///   DATABASE_URL   conninfo do libpq, ex.: "host=meu-rds.exemplo.com dbname=app user=app password=..."
///   API_TOKEN      token Bearer aceito em /api/v1 (obrigatório)
///   RATES_URL      base da API de cotações (padrão https://api.exchangerate.host)
///   CORS_ORIGINS   origens permitidas, separadas por vírgula (padrão: nenhuma)
module app;

import vela;
import vela.db;

import core.stdc.stdlib : getenv;
import core.time : seconds;
import core.stdc.string : strlen;

// ---------------------------------------------------------------- configuração

struct Config
{
    ushort port = 8080;
    string databaseUrl;
    string apiToken;
    string ratesUrl = "https://api.exchangerate.host";
    string[] corsOrigins;
}

__gshared Config config; // escrito uma vez no main, lido por todos os workers

string env(const(char)* name, string fallback = null)
{
    auto p = getenv(name);
    return p is null ? fallback : p[0 .. strlen(p)].idup;
}

// ---------------------------------------------------------------- DTOs

struct UserInput
{
    @minLength(2) @maxLength(80) string name;
    @minLength(3) @maxLength(120) string email;
    @inRange(0, 150) int age;
}

struct User
{
    int id;
    string name;
    string email;
    int age;
}

struct Rates
{
    string base;
    string raw;
}

/// Quem chamou, definido pelo middleware de autenticação.
struct Caller
{
    string token;
}

// ---------------------------------------------------------------- banco

PgPool db()
{
    PgConfig cfg;
    cfg.conninfo = config.databaseUrl;
    cfg.maxConns = 8;
    cfg.cacheStatements = true;
    return pgPool(cfg); // um pool por worker
}

void ensureSchema()
{
    // roda no main, antes do servidor: sem fibers, o driver cai no modo bloqueante
    auto c = PgConn.connect(config.databaseUrl, seconds(10), seconds(30));
    scope (exit) c.shutdown();
    c.exec("create table if not exists users(id serial primary key, name text not null, "
        ~ "email text not null unique, age int not null)");
}

// ---------------------------------------------------------------- handlers

string health() => "ok";

@summary("Lista usuários")
User[] listUsers(int limit = 20, int offset = 0)
{
    if (limit < 1 || limit > 100)
        throw new HttpError(422, "limit deve estar entre 1 e 100");
    return db.query("select id, name, email, age from users order by id limit $1 offset $2", limit, offset)
        .rowsAs!User;
}

@summary("Busca um usuário")
User getUser(int id)
{
    auto rows = db.query("select id, name, email, age from users where id = $1", id).rowsAs!User;
    if (rows.length == 0)
        throw new HttpError(404, "usuário não encontrado");
    return rows[0];
}

@summary("Cria um usuário")
WithStatus!User createUser(JsonBody!UserInput body_)
{
    auto u = db.query("insert into users(name, email, age) values ($1, $2, $3) returning id, name, email, age",
        body_.name, body_.email, body_.age).one!User;
    return withStatus(201, u);
}

@summary("Atualiza um usuário")
User updateUser(int id, JsonBody!UserInput body_)
{
    auto rows = db.query("update users set name = $2, email = $3, age = $4 where id = $1 "
        ~ "returning id, name, email, age", id, body_.name, body_.email, body_.age).rowsAs!User;
    if (rows.length == 0)
        throw new HttpError(404, "usuário não encontrado");
    return rows[0];
}

@summary("Remove um usuário")
void deleteUser(int id)
{
    if (db.query("delete from users where id = $1 returning id", id).rows == 0)
        throw new HttpError(404, "usuário não encontrado");
}

@summary("Cotação vinda de uma API externa")
Response rates(string currency, Local!RequestId rid)
{
    foreach (char ch; currency)
        if (!((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')))
            throw new HttpError(422, "moeda inválida");
    HeaderPair[1] h = [HeaderPair("X-Request-Id", rid.value.idup)];
    auto r = httpClient().get(config.ratesUrl ~ "/latest?base=" ~ currency, h[]);
    if (!r.ok)
        throw new HttpError(502, "a API de cotações respondeu " ~ (r.status == 404 ? "404" : "com erro"));
    return Response(200, "application/json", r.body);
}

string whoami(Local!Caller c) => c.token.length > 4 ? c.token[0 .. 4] ~ "…" : "?";

// ---------------------------------------------------------------- app

App buildApp()
{
    auto app = new App;
    app.redirectTrailingSlash = true;

    app.use(requestId());
    app.use(accessLog());
    if (config.corsOrigins.length)
        app.use(cors(CorsConfig(config.corsOrigins, "GET, POST, PUT, DELETE", "Authorization, Content-Type")));

    // erros do banco viram respostas HTTP
    app.onError((Context ctx, Exception e) {
        if (auto he = cast(HttpError) e)
            return ctx.text(he.msg, he.status);
        if (auto pe = cast(PgError) e)
        {
            if (pe.isUniqueViolation)
                return ctx.text("já existe um registro com esse valor", 409);
            if (cast(PgTimeout) pe)
                return ctx.text("banco de dados demorou demais", 504);
        }
        if (cast(HttpClientTimeout) e)
            return ctx.text("serviço externo demorou demais", 504);
        ctx.text("erro interno", 500);
    });

    app.get!("/health", health);

    auto api = app.group("/api/v1");
    api.use((Context ctx, Next next) {
        auto token = bearerToken(ctx);
        if (token.length == 0 || token != config.apiToken)
        {
            ctx.setHeader("WWW-Authenticate", "Bearer");
            throw new HttpError(401, "token ausente ou inválido");
        }
        ctx.locals.set(Caller(token.idup));
        next();
    });
    api.get!("/users", listUsers);
    api.get!("/users/{id}", getUser);
    api.post!("/users", createUser);
    api.put!("/users/{id}", updateUser);
    api.del!("/users/{id}", deleteUser);
    api.get!("/rates/{currency}", rates);
    api.get!("/whoami", whoami);

    app.serveStatic("/assets", "public");
    app.serveOpenApi(OpenApiInfo("vela api", "1.0.0", "Exemplo de API com Postgres e API externa"));
    return app;
}

void main()
{
    config.port = cast(ushort) parsePort(env("PORT", "8080"));
    config.databaseUrl = env("DATABASE_URL");
    config.apiToken = env("API_TOKEN");
    config.ratesUrl = env("RATES_URL", config.ratesUrl);
    foreach (o; split(env("CORS_ORIGINS", ""), ','))
        if (o.length)
            config.corsOrigins ~= o;

    if (config.databaseUrl.length == 0 || config.apiToken.length == 0)
    {
        import core.stdc.stdio : fputs, stderr;

        fputs("defina DATABASE_URL e API_TOKEN\n", stderr);
        throw new Exception("configuração incompleta");
    }
    ensureSchema();

    ServerConfig sc;
    sc.port = config.port;
    sc.requestTimeoutMs = 20_000;
    buildApp().serve(sc);
}

uint parsePort(string s)
{
    uint v;
    foreach (c; s)
        v = v * 10 + (c - '0');
    return v;
}

string[] split(string s, char sep)
{
    string[] out_;
    size_t from;
    foreach (i; 0 .. s.length + 1)
        if (i == s.length || s[i] == sep)
        {
            out_ ~= s[from .. i];
            from = i + 1;
        }
    return out_;
}
