/// The composition root: which adapter implements each port, and which routes the app serves. `buildApp` runs once per
/// worker (andaime's model), so everything it creates belongs to that worker and needs no locks.
module app 2025;

@safe:

import andaime;
{{#pg}}
import andaime.db : pgPool;
import config : config, Store;
{{/pg}}
import domain.errors : Conflict, NotFound, RuleViolation;
import usecases.system : Clock, IdGenerator, TokenGenerator;
import adapters.http.errors : apiError;
import adapters.system.clock : SystemClock;
import adapters.system.random : RandomTokens, Uuid7Ids;
// andaime:imports

/// The adapter behind each port.
struct Adapters
{
    Clock clock;
    IdGenerator ids;
    TokenGenerator tokens;
    // andaime:adapters
}

/// The system's effects: the same in every store (the tests replace them with `tests/fakes.d`).
private void systemAdapters(ref Adapters a)
{
    a.clock = new SystemClock;
    a.ids = new Uuid7Ids;
    a.tokens = new RandomTokens;
}
{{#pg}}

/// Postgres adapters over this worker's pool. Nothing connects until the first query.
Adapters postgresAdapters()
{
    auto db = pgPool(config.databaseUrl);
    Adapters a;
    systemAdapters(a);
    // andaime:postgres
    return a;
}
{{/pg}}

/// In-memory adapters: for tests{{#pg}}, and for `STORE=memory`{{/pg}}.
Adapters memoryAdapters()
{
    Adapters a;
    systemAdapters(a);
    // andaime:memory
    return a;
}

/// This thread's adapters, {{#pg}}chosen by `STORE` and {{/pg}}built on first use.
Adapters currentAdapters()
{
    static Adapters current; // thread-local, like all module state in D
    static bool built;
    if (!built)
    {
{{#pg}}
        current = config.store == Store.memory ? memoryAdapters() : postgresAdapters();
{{/pg}}
{{^pg}}
        current = memoryAdapters();
{{/pg}}
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
    app.errorBody(&apiError); // every error answers {"message": "...", "code": "..."}

    auto api = app.group("/api/v1");
    // andaime:mount

    app.serveOpenApi(OpenApiInfo("{{app}}", "0.1.0"));
    return app;
}
