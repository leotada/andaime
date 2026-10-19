/// Companies: the API end to end over in-memory adapters, the unit of work that writes both tables, and the policies.
module tests.companies 2025;

@safe:

import andaime;
import andaime.web.testing;
import app : buildAppWith, memoryAdapters;
import domain.companies;
import domain.errors : Forbidden;
import domain.tenancy;
import usecases.companies;
import adapters.memory.companies : MemoryCompanyRepository, MemoryMembershipRepository;
import adapters.memory.uow : MemoryUnitOfWork;
import tests.fakes : FixedClock, SequenceIds;

unittest // create a company, act in it, and see its members only as its owner
{
    auto c = TestClient(buildAppWith(memoryAdapters()));
    assert(c.post("/api/v1/companies", `{"name":"Acme"}`).status == 401, "the routes need to know who calls");

    auto r = c.post("/api/v1/companies", `{"name":"Acme"}`, HeaderField("X-User-Id", "7"));
    assert(r.status == 201, r.body);
    auto id = r.body[7 .. 43]; // {"id":"<36 characters>",...
    assert(r.body[0 .. 7] == `{"id":"` && r.body[43 .. 59] == `","name":"Acme",`, r.body);

    r = c.get("/api/v1/companies/current", HeaderField("X-User-Id", "7"), HeaderField("X-Company-Id", id));
    assert(r.status == 200 && r.body[43 .. 59] == `","name":"Acme",`, r.body);

    r = c.get("/api/v1/companies/current/members", HeaderField("X-User-Id", "7"), HeaderField("X-Company-Id", id),
        HeaderField("X-Role", "owner"));
    assert(r.status == 200 && r.body[0 .. 30] == `[{"user_id":7,"role":"owner","`, r.body);

    r = c.get("/api/v1/companies/current/members", HeaderField("X-User-Id", "8"), HeaderField("X-Company-Id", id));
    assert(r.status == 403 && r.body == `{"message":"only an admin or the owner sees the members","code":"forbidden"}`,
        r.body);
    assert(c.get("/api/v1/companies/current", HeaderField("X-User-Id", "7")).status == 400, "no company chosen");
}

/// A membership store that fails, to see the unit of work take the company back.
final class BrokenMemberships : MembershipRepository
{
    void add(Tenant, Membership) { throw new Exception("the database went away"); }
    Membership[] list(Tenant) => null;
}

unittest // CreateCompany writes both tables in one unit of work: a failure in the second leaves neither
{
    auto uow = new MemoryUnitOfWork;
    auto companies = uow.track(new MemoryCompanyRepository);
    auto memberships = uow.track(new MemoryMembershipRepository);
    auto clock = new FixedClock;
    auto ids = new SequenceIds;
    auto create = new CreateCompany(uow, companies, memberships, clock, ids);

    auto acme = create.execute(7, NewCompany("Acme"));
    assert(acme.createdAt == clock.current && companies.find(acme.tenant).has);
    assert(memberships.list(acme.tenant) == [Membership(acme.id, 7, Role.owner, clock.current)]);

    auto failing = new CreateCompany(uow, companies, new BrokenMemberships, clock, ids);
    bool threw;
    try
        failing.execute(8, NewCompany("Beta"));
    catch (Exception)
        threw = true;
    assert(threw);
    auto replay = new SequenceIds; // the same sequence: Acme's id, then Beta's
    replay.newId();
    assert(!companies.find(Tenant(replay.newId())).has, "the company was rolled back with the membership");
    assert(companies.find(acme.tenant).has, "what was committed before stays");
}

unittest // the policies: only an admin or the owner lists the members
{
    auto memberships = new MemoryMembershipRepository;
    auto list = new ListMembers(memberships);
    auto company = Tenant(new SequenceIds().newId());
    assert(list.execute(Actor(1, company, Role.admin)).length == 0);
    bool forbidden;
    try
        list.execute(Actor(2, company, Role.member));
    catch (Forbidden)
        forbidden = true;
    assert(forbidden);
}
{{#pg}}

unittest // the Postgres adapters, when TEST_DATABASE_URL names a database for tests (its companies tables are emptied)
{
    import adapters.postgres.companies : PgCompanyRepository, PgMembershipRepository;
    import adapters.postgres.uow : PgUnitOfWork;
    import andaime.db : pgPool;
    import core.stdc.stdlib : getenv;
    import core.stdc.string : strlen;

    auto url = (() @trusted {
        auto p = getenv("TEST_DATABASE_URL"); // sound: copied before anything can change the environment
        return p is null ? null : p[0 .. strlen(p)].idup;
    })();
    if (url.length == 0)
        return;
    auto db = pgPool(url);
    db.exec("truncate memberships, companies");
    auto companies = new PgCompanyRepository(db);
    auto memberships = new PgMembershipRepository(db);
    auto clock = new FixedClock;
    auto ids = new SequenceIds;
    auto create = new CreateCompany(new PgUnitOfWork(db), companies, memberships, clock, ids);

    auto acme = create.execute(7, NewCompany("Acme"));
    assert(companies.find(acme.tenant).get == acme);
    assert(memberships.list(acme.tenant) == [Membership(acme.id, 7, Role.owner, clock.current)]);

    // the second insert breaks (user 7 is already a member): the first one goes with it
    auto other = Company(ids.newId(), "Beta", clock.now());
    bool conflict;
    try
        new PgUnitOfWork(db).run(() {
            companies.add(other);
            memberships.add(acme.tenant, Membership(acme.id, 7, Role.member, clock.now()));
        });
    catch (Exception)
        conflict = true;
    assert(conflict && !companies.find(other.tenant).has, "Beta was rolled back");
}
{{/pg}}
