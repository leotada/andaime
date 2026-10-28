/// The composition root: which adapter implements each port, and which routes the app serves. `buildApp` runs once per
/// worker (andaime's model), so everything it creates belongs to that worker and needs no locks.
module app 2025;

@safe:

import andaime;
import andaime.db : pgPool;
import config : config, Store;
import domain.errors : Conflict, Forbidden, NotFound, RuleViolation;
import usecases.system : Clock, IdGenerator, TokenGenerator;
import usecases.uow : UnitOfWork;
import adapters.http.errors : apiError;
import adapters.memory.uow : MemoryUnitOfWork;
import adapters.postgres.uow : PgUnitOfWork;
import adapters.system.clock : SystemClock;
import adapters.system.random : RandomTokens, Uuid7Ids;
import usecases.companies;
import adapters.http.auth : devAuth;
import adapters.http.companies : CompanyController;
import adapters.memory.companies : MemoryCompanyRepository, MemoryMembershipRepository;
import adapters.postgres.companies : PgCompanyRepository, PgMembershipRepository;
import andaime.jobs : InMemoryJobStore, JobStore;
import andaime.jobs.pg : PgJobStore;
import usecases.users;
import adapters.http.users : UserController;
import adapters.memory.users : MemoryUserRepository;
import adapters.postgres.users : PgUserRepository;
import adapters.jobs.users : QueuedSendWelcome;
// andaime:imports

/// The adapter behind each port.
struct Adapters
{
    UnitOfWork uow;
    Clock clock;
    IdGenerator ids;
    TokenGenerator tokens;
    CompanyRepository companies;
    MembershipRepository memberships;
    JobStore jobStore;
    UserRepository users;
    SendWelcomeScheduler sendWelcome;
    // andaime:adapters
}

/// The system's effects: the same in every store (the tests replace them with `tests/fakes.d`).
private void systemAdapters(ref Adapters a)
{
    a.clock = new SystemClock;
    a.ids = new Uuid7Ids;
    a.tokens = new RandomTokens;
}

/// Postgres adapters over this worker's pool. Nothing connects until the first query.
Adapters postgresAdapters()
{
    auto db = pgPool(config.databaseUrl);
    Adapters a;
    systemAdapters(a);
    a.uow = new PgUnitOfWork(db); // ambient: the repositories over `db` join its transactions
    a.companies = new PgCompanyRepository(db);
    a.memberships = new PgMembershipRepository(db);
    a.jobStore = new PgJobStore(db); // over the repositories' pool: an enqueue joins its transaction
    a.users = new PgUserRepository(db);
    a.sendWelcome = new QueuedSendWelcome(a.jobStore);
    // andaime:postgres
    return a;
}

/// In-memory adapters: for tests, and for `STORE=memory`.
Adapters memoryAdapters()
{
    Adapters a;
    systemAdapters(a);
    auto uow = new MemoryUnitOfWork; // each store it tracks rolls back with the others
    a.uow = uow;
    a.companies = uow.track(new MemoryCompanyRepository);
    a.memberships = uow.track(new MemoryMembershipRepository);
    a.jobStore = uow.track(new InMemoryJobStore);
    a.users = uow.track(new MemoryUserRepository);
    a.sendWelcome = new QueuedSendWelcome(a.jobStore); // a rollback of `uow` takes its jobs back
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
    app.mapError!Forbidden(403);
    app.mapError!Conflict(409);
    app.mapError!RuleViolation(422);
    app.errorBody(&apiError); // every error answers {"message": "...", "code": "..."}

    auto api = app.group("/api/v1");
    auto members = app.group("/api/v1"); // the routes that know who calls (adapters/http/auth.d)
    members.use(devAuth());
    members.mount(new CompanyController(new CreateCompany(a.uow, a.companies, a.memberships, a.clock, a.ids),
        new GetCompany(a.companies), new ListMembers(a.memberships)));
    api.mount(new UserController(new ListUsers(a.users), new GetUser(a.users), new CreateUser(a.users),
        new UpdateUser(a.users), new DeleteUser(a.users)));
    // andaime:mount

    app.serveOpenApi(OpenApiInfo("clean", "0.1.0"));
    return app;
}
