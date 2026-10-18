/// A "real" API in andaime: users in Postgres (RDS), a quote coming from an
/// external API, Bearer authentication, CORS, static files and OpenAPI.
///
/// Environment variables:
///   PORT           port (8080)
///   DATABASE_URL   libpq conninfo, e.g. "host=my-rds.example.com dbname=app user=app password=..."
///   API_TOKEN      Bearer token accepted on /api/v1 (required)
///   RATES_URL      base of the exchange-rates API (default https://api.exchangerate.host)
///   CORS_ORIGINS   allowed origins, comma-separated (default: none)
module app;

@safe:

import andaime;
import andaime.db;

import core.stdc.stdlib : getenv;
import core.time : seconds;
import core.stdc.string : strlen;

// ---------------------------------------------------------------- configuration

struct Config
{
    ushort port = 8080;
    string databaseUrl;
    string apiToken;
    string ratesUrl = "https://api.exchangerate.host";
    string[] corsOrigins;
}

private __gshared Config gConfig; // written once in main before serving, then read-only by all workers

/// `@trusted` accessor: `__gshared` data is `@system`, but `main` fills it before the server starts and the workers
/// only read it. It hands out `const`, never a mutable ref: `@safe` code can then not write what other threads read.
ref const(Config) config() @trusted => gConfig;

/// The only writer; `main` calls it once, before `serve`.
void setConfig(Config c) @system
{
    gConfig = c;
}

string env(const(char)* name, string fallback = null) @trusted // C string -> copied D string
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

/// Who called, set by the authentication middleware.
struct Caller
{
    string token;
}

// ---------------------------------------------------------------- database

PgPool db()
{
    PgConfig cfg;
    cfg.conninfo = config.databaseUrl;
    cfg.maxConns = 8;
    cfg.cacheStatements = true;
    return pgPool(cfg); // one pool per worker
}

void ensureSchema()
{
    // runs in main, before the server: no fibers, so the driver falls back to blocking mode
    auto c = PgConn.connect(config.databaseUrl, seconds(10), seconds(30));
    scope (exit) c.shutdown();
    c.exec("create table if not exists users(id serial primary key, name text not null, "
        ~ "email text not null unique, age int not null)");
}

// ---------------------------------------------------------------- handlers

string health() => "ok";

@summary("List users")
User[] listUsers(int limit = 20, int offset = 0)
{
    if (limit < 1 || limit > 100)
        throw new HttpError(422, "limit must be between 1 and 100");
    return db.query("select id, name, email, age from users order by id limit $1 offset $2", limit, offset)
        .rowsAs!User;
}

@summary("Fetch a user")
User getUser(int id)
{
    auto rows = db.query("select id, name, email, age from users where id = $1", id).rowsAs!User;
    if (rows.length == 0)
        throw new HttpError(404, "user not found");
    return rows[0];
}

@summary("Create a user")
WithStatus!User createUser(JsonBody!UserInput body_)
{
    auto u = db.query("insert into users(name, email, age) values ($1, $2, $3) returning id, name, email, age",
        body_.name, body_.email, body_.age).one!User;
    return withStatus(201, u);
}

@summary("Update a user")
User updateUser(int id, JsonBody!UserInput body_)
{
    auto rows = db.query("update users set name = $2, email = $3, age = $4 where id = $1 "
        ~ "returning id, name, email, age", id, body_.name, body_.email, body_.age).rowsAs!User;
    if (rows.length == 0)
        throw new HttpError(404, "user not found");
    return rows[0];
}

@summary("Delete a user")
void deleteUser(int id)
{
    if (db.query("delete from users where id = $1 returning id", id).rows == 0)
        throw new HttpError(404, "user not found");
}

@summary("Quote from an external API")
Response rates(string currency, Local!RequestId rid)
{
    foreach (char ch; currency)
        if (!((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')))
            throw new HttpError(422, "invalid currency");
    HeaderPair[1] h = [HeaderPair("X-Request-Id", rid.value.idup)];
    auto r = httpClient().get(config.ratesUrl ~ "/latest?base=" ~ currency, h[]);
    if (!r.ok)
        throw new HttpError(502, "the rates API answered " ~ (r.status == 404 ? "404" : "with an error"));
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
        app.use(cors(CorsConfig(config.corsOrigins.dup, "GET, POST, PUT, DELETE", "Authorization, Content-Type")));

    // database errors become HTTP responses
    app.onError((Context ctx, Exception e) {
        if (auto he = cast(HttpError) e)
            return ctx.text(he.msg, he.status);
        if (auto pe = cast(PgError) e)
        {
            if (pe.isUniqueViolation)
                return ctx.text("a record with that value already exists", 409);
            if (cast(PgTimeout) pe)
                return ctx.text("database took too long", 504);
        }
        if (cast(HttpClientTimeout) e)
            return ctx.text("external service took too long", 504);
        ctx.text("internal error", 500);
    });

    app.get!("/health", health);

    auto api = app.group("/api/v1");
    api.use((Context ctx, Next next) {
        auto token = bearerToken(ctx);
        if (token.length == 0 || token != config.apiToken)
        {
            ctx.setHeader("WWW-Authenticate", "Bearer");
            throw new HttpError(401, "missing or invalid token");
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
    app.serveOpenApi(OpenApiInfo("andaime api", "1.0.0", "Example API with Postgres and an external API"));
    return app;
}

void main()
{
    Config c;
    c.port = cast(ushort) parsePort(env("PORT", "8080"));
    c.databaseUrl = env("DATABASE_URL");
    c.apiToken = env("API_TOKEN");
    c.ratesUrl = env("RATES_URL", c.ratesUrl);
    foreach (o; split(env("CORS_ORIGINS", ""), ','))
        if (o.length)
            c.corsOrigins ~= o;

    if (c.databaseUrl.length == 0 || c.apiToken.length == 0)
    {
        throw new Exception("incomplete configuration: set DATABASE_URL and API_TOKEN");
    }
    (() @trusted => setConfig(c))(); // sound: runs once on the main thread, before any worker exists
    ensureSchema();

    ServerConfig sc;
    sc.port = config.port;
    sc.requestTimeoutMs = 20_000;
    serve(&buildApp, sc);
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
