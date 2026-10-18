/// The composition root: which adapter implements each port, and which routes the app serves. `buildApp` runs once per
/// worker (andaime's model), so everything it creates belongs to that worker and needs no locks.
module app;

@safe:

import andaime;
import andaime.db : pgPool;
import config : config, Store;
import domain.errors : Conflict, NotFound, RuleViolation;
import usecases.users;
import adapters.http.users : UserController;
import adapters.memory.users : MemoryUserRepository;
import adapters.postgres.users : PgUserRepository;
// andaime:imports

/// The adapter behind each port.
struct Adapters
{
    UserRepository users;
    // andaime:adapters
}

/// Postgres adapters over this worker's pool. Nothing connects until the first query.
Adapters postgresAdapters()
{
    auto db = pgPool(config.databaseUrl);
    Adapters a;
    a.users = new PgUserRepository(db);
    // andaime:postgres
    return a;
}

/// In-memory adapters: for tests, and for `STORE=memory`.
Adapters memoryAdapters()
{
    Adapters a;
    a.users = new MemoryUserRepository;
    // andaime:memory
    return a;
}

/// This thread's adapters, chosen by `STORE` and built on first use.
Adapters currentAdapters()
{
    static Adapters current; // thread-local, like all module state in D
    static bool built;
    if (!built)
    {
        current = config.store == Store.memory ? memoryAdapters() : postgresAdapters();
        built = true;
    }
    return current;
}

/// The app this worker serves.
App buildApp() => buildAppWith(currentAdapters());

/// The app over the given adapters (the tests pass `memoryAdapters()`).
App buildAppWith(Adapters a)
{
    auto app = new App;
    app.use(requestId());
    app.use(accessLog());
    app.mapError!NotFound(404);
    app.mapError!Conflict(409);
    app.mapError!RuleViolation(422);

    auto api = app.group("/api/v1");
    api.mount(new UserController(new ListUsers(a.users), new GetUser(a.users), new CreateUser(a.users),
        new UpdateUser(a.users), new DeleteUser(a.users)));
    // andaime:mount

    app.serveOpenApi(OpenApiInfo("clean", "0.1.0"));
    return app;
}
