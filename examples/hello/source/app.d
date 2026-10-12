/// Exemplo de ergonomia do vela: CRUD de usuários em memória.
/// A assinatura de cada função É o contrato HTTP: o vela lê os tipos e os
/// nomes dos parâmetros em compilação e gera a extração e a validação.
module app;

import vela;
import core.time : MonoTime;
import std.stdio : writefln;

// ---------------------------------------------------------------- DTOs

struct UserInput
{
    @minLength(2) @maxLength(60) string name;
    @inRange(0, 150) int age;
    Optional!string email; // ausente ou null => opcional
}

struct UserResponse
{
    long id;
    string name;
    int age;
    Optional!string email;
}

struct Stats
{
    ulong requests;
    size_t users;
}

enum Order { asc, desc }

// "Banco" em memória. Atenção: variáveis de módulo em D são thread-local;
// com vários workers (M2) cada um teria a sua cópia. Use um banco de verdade.
private UserResponse[long] users;
private long nextId = 1;

// ---------------------------------------------------------------- handlers

string health() => "ok";

/// GET /users?limit=20&offset=0&order=desc  (defaults tornam a query opcional)
UserResponse[] listUsers(int limit = 20, int offset = 0, Order order = Order.asc)
{
    auto all = users.values;
    foreach (i; 1 .. all.length) // insertion sort: evita importar std.algorithm
        for (size_t j = i; j > 0 && (order == Order.asc ? all[j - 1].id > all[j].id
                : all[j - 1].id < all[j].id); j--)
        {
            auto t = all[j];
            all[j] = all[j - 1];
            all[j - 1] = t;
        }
    if (offset >= all.length)
        return null;
    auto page = all[offset .. $];
    return page.length > limit ? page[0 .. limit] : page;
}

/// GET /users/{id}
UserResponse getUser(long id)
{
    if (auto u = id in users)
        return *u;
    throw new HttpError(404, "usuário não encontrado");
}

/// POST /users -> 201
WithStatus!UserResponse createUser(JsonBody!UserInput body)
{
    auto u = UserResponse(nextId++, body.name, body.age, body.email);
    users[u.id] = u;
    return withStatus(201, u);
}

/// PUT /users/{id} — a assinatura do enunciado do projeto
UserResponse updateUser(long id, JsonBody!UserInput body, Header!"Authorization" auth)
{
    if (auth != "Bearer segredo")
        throw new HttpError(401, "token inválido");
    auto u = id in users;
    if (u is null)
        throw new HttpError(404, "usuário não encontrado");
    *u = UserResponse(id, body.name, body.age, body.email);
    return *u;
}

/// DELETE /users/{id} -> 204 (retorno void)
void deleteUser(long id)
{
    if (!users.remove(id))
        throw new HttpError(404, "usuário não encontrado");
}

/// GET /files/{*path} — captura o resto do caminho; header opcional
string file(string path, Optional!(Header!"X-Trace-Id") trace)
{
    return "arquivo: " ~ path ~ (trace.has ? " trace=" ~ trace.get.idup : "");
}

// ---------------------------------------------------------------- controller com estado

final class StatsController
{
    private ulong hits;

    void count()
    {
        hits++;
    }

    @Get("/stats")
    Stats stats() => Stats(hits, users.length);
}

// ---------------------------------------------------------------- middleware

void logger(Context ctx, Next next)
{
    immutable t0 = MonoTime.currTime;
    next();
    writefln("%s %s -> %d (%d µs)", ctx.request.method, ctx.request.path,
        ctx.response.status, (MonoTime.currTime - t0).total!"usecs");
}

// ---------------------------------------------------------------- montagem

App buildApp()
{
    auto app = new App;
    auto stats = new StatsController;

    app.use(&logger);
    app.use((Context ctx, Next next) { stats.count(); next(); });

    app.get!("/health", health);
    app.get!("/users", listUsers);
    app.get!("/users/{id}", getUser);
    app.post!("/users", createUser);
    app.put!("/users/{id}", updateUser);
    app.del!("/users/{id}", deleteUser);
    app.get!("/files/{*path}", file);
    app.mount(stats);

    // lambda local que captura uma dependência: vira um closure comum
    immutable greeting = "olá";
    app.get!("/hello/{name}", (string name) => greeting ~ ", " ~ name);
    return app;
}

version (unittest) {} else
void main()
{
    ServerConfig cfg;
    cfg.port = 8080;
    // O "banco" deste exemplo é uma variável de módulo, que em D é thread-local:
    // com vários workers cada um teria a sua cópia. Um worker só mantém o exemplo
    // coerente. Com um banco de verdade, deixe workers = 0 (um por núcleo).
    cfg.workers = 1;
    buildApp().serve(cfg);
}

// ---------------------------------------------------------------- testes sem rede

unittest
{
    auto c = TestClient(buildApp());

    auto r = c.post("/users", `{"name":"Ana","age":31}`);
    assert(r.status == 201, r.body);
    assert(r.body == `{"id":1,"name":"Ana","age":31,"email":null}`, r.body);

    r = c.get("/users/1");
    assert(r.status == 200 && r.contentType == "application/json");

    r = c.get("/users/abc");
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"loc":["path","id"],"msg":"esperado inteiro (long)"}]}`, r.body);

    r = c.put("/users/1", `{"name":"Ana Maria","age":32}`);
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"loc":["header","Authorization"],"msg":"header obrigatório ausente"}]}`, r.body);

    r = c.put("/users/1", `{"name":"Ana Maria","age":32,"email":"ana@ex.com"}`, hdr("Authorization", "Bearer segredo"));
    assert(r.status == 200);
    assert(r.body == `{"id":1,"name":"Ana Maria","age":32,"email":"ana@ex.com"}`, r.body);

    r = c.post("/users", `{"name":"A","age":200}`);
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"loc":["body","name"],"msg":"abaixo do comprimento mínimo de 2"},`
        ~ `{"loc":["body","age"],"msg":"fora da faixa permitida"}]}`, r.body);

    c.post("/users", `{"name":"Bia","age":25}`);
    r = c.get("/users?order=desc&limit=1");
    assert(r.status == 200 && r.body == `[{"id":2,"name":"Bia","age":25,"email":null}]`, r.body);

    r = c.get("/users?limit=muitos");
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"loc":["query","limit"],"msg":"esperado inteiro (int)"}]}`, r.body);

    r = c.del("/users/1");
    assert(r.status == 204);
    assert(c.get("/users/1").status == 404);

    r = c.get("/files/css/app.css", hdr("X-Trace-Id", "t-9"));
    assert(r.body == "arquivo: css/app.css trace=t-9", r.body);

    r = c.post("/health", "");
    assert(r.status == 405 && r.header("Allow") == "GET");

    r = c.get("/hello/mundo%21");
    assert(r.body == "olá, mundo!", r.body);

    r = c.get("/stats");
    assert(r.status == 200 && r.body == `{"requests":15,"users":1}`, r.body);
}
