/// vela ergonomics example: in-memory CRUD of users.
/// The signature of each function IS the HTTP contract: vela reads the types and
/// parameter names at compile time and generates the extraction and validation.
module app;

import vela;
import core.time : MonoTime;
import std.stdio : writefln;

// ---------------------------------------------------------------- DTOs

struct UserInput
{
    @minLength(2) @maxLength(60) string name;
    @inRange(0, 150) int age;
    Optional!string email; // absent or null => optional
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

// In-memory "database". Beware: module variables in D are thread-local;
// with several workers (M2) each would have its own copy. Use a real database.
private UserResponse[long] users;
private long nextId = 1;

// ---------------------------------------------------------------- handlers

string health() => "ok";

/// GET /users?limit=20&offset=0&order=desc  (defaults make the query optional)
UserResponse[] listUsers(int limit = 20, int offset = 0, Order order = Order.asc)
{
    auto all = users.values;
    foreach (i; 1 .. all.length) // insertion sort: avoids importing std.algorithm
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
    throw new HttpError(404, "user not found");
}

/// POST /users -> 201
WithStatus!UserResponse createUser(JsonBody!UserInput body)
{
    auto u = UserResponse(nextId++, body.name, body.age, body.email);
    users[u.id] = u;
    return withStatus(201, u);
}

/// PUT /users/{id} — the signature from the project brief
UserResponse updateUser(long id, JsonBody!UserInput body, Header!"Authorization" auth)
{
    if (auth != "Bearer segredo")
        throw new HttpError(401, "invalid token");
    auto u = id in users;
    if (u is null)
        throw new HttpError(404, "user not found");
    *u = UserResponse(id, body.name, body.age, body.email);
    return *u;
}

/// DELETE /users/{id} -> 204 (void return)
void deleteUser(long id)
{
    if (!users.remove(id))
        throw new HttpError(404, "user not found");
}

/// GET /files/{*path} — captures the rest of the path; optional header
string file(string path, Optional!(Header!"X-Trace-Id") trace)
{
    return "file: " ~ path ~ (trace.has ? " trace=" ~ trace.get.idup : "");
}

// ---------------------------------------------------------------- controller with state

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

// ---------------------------------------------------------------- assembly

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

    // local lambda that captures a dependency: becomes an ordinary closure
    immutable greeting = "hello";
    app.get!("/hello/{name}", (string name) => greeting ~ ", " ~ name);
    return app;
}

version (unittest) {} else
void main()
{
    ServerConfig cfg;
    cfg.port = 8080;
    // This example's "database" is a module variable, which in D is thread-local:
    // with several workers each would have its own copy. A single worker keeps the example
    // consistent. With a real database, leave workers = 0 (one per core).
    cfg.workers = 1;
    buildApp().serve(cfg);
}

// ---------------------------------------------------------------- tests without network

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
    assert(r.body == `{"detail":[{"loc":["path","id"],"msg":"expected an integer (long)"}]}`, r.body);

    r = c.put("/users/1", `{"name":"Ana Maria","age":32}`);
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"loc":["header","Authorization"],"msg":"required header missing"}]}`, r.body);

    r = c.put("/users/1", `{"name":"Ana Maria","age":32,"email":"ana@ex.com"}`, hdr("Authorization", "Bearer segredo"));
    assert(r.status == 200);
    assert(r.body == `{"id":1,"name":"Ana Maria","age":32,"email":"ana@ex.com"}`, r.body);

    r = c.post("/users", `{"name":"A","age":200}`);
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"loc":["body","name"],"msg":"below the minimum length of 2"},`
        ~ `{"loc":["body","age"],"msg":"outside the allowed range"}]}`, r.body);

    c.post("/users", `{"name":"Bia","age":25}`);
    r = c.get("/users?order=desc&limit=1");
    assert(r.status == 200 && r.body == `[{"id":2,"name":"Bia","age":25,"email":null}]`, r.body);

    r = c.get("/users?limit=muitos");
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"loc":["query","limit"],"msg":"expected an integer (int)"}]}`, r.body);

    r = c.del("/users/1");
    assert(r.status == 204);
    assert(c.get("/users/1").status == 404);

    r = c.get("/files/css/app.css", hdr("X-Trace-Id", "t-9"));
    assert(r.body == "file: css/app.css trace=t-9", r.body);

    r = c.post("/health", "");
    assert(r.status == 405 && r.header("Allow") == "GET");

    r = c.get("/hello/world%21");
    assert(r.body == "hello, world!", r.body);

    r = c.get("/stats");
    assert(r.status == 200 && r.body == `{"requests":15,"users":1}`, r.body);
}
