/// Users: the API end to end over in-memory adapters, and the repository contract on each adapter.
module tests.users 2025;

@safe:

import andaime;
import andaime.web.testing;
import app : buildAppWith, memoryAdapters;
import domain.errors : Conflict;
import domain.users;
import usecases.users;
import adapters.memory.users : MemoryUserRepository;

unittest // create, read, list, replace and delete through HTTP
{
    auto c = TestClient(buildAppWith(memoryAdapters()));

    auto r = c.post("/api/v1/users", `{"name":"name 1","email":"email 1"}`);
    assert(r.status == 201, r.body);
    assert(r.body == `{"id":1,"name":"name 1","email":"email 1"}`, r.body);

    r = c.get("/api/v1/users/1");
    assert(r.status == 200 && r.body == `{"id":1,"name":"name 1","email":"email 1"}`, r.body);

    r = c.get("/api/v1/users?limit=10");
    assert(r.status == 200 && r.body == `[{"id":1,"name":"name 1","email":"email 1"}]`, r.body);

    r = c.put("/api/v1/users/1", `{"name":"name 2","email":"email 2"}`);
    assert(r.status == 200 && r.body == `{"id":1,"name":"name 2","email":"email 2"}`, r.body);

    r = c.del("/api/v1/users/1");
    assert(r.status == 204, r.body);

    r = c.get("/api/v1/users/1");
    assert(r.status == 404 && r.body == `{"detail":"user not found"}`, r.body);
}

unittest // a body without its fields and a bad page are 422; a taken unique value is 409
{
    auto c = TestClient(buildAppWith(memoryAdapters()));
    assert(c.post("/api/v1/users", `{}`).status == 422);
    assert(c.get("/api/v1/users?limit=0").status == 422);
    assert(c.post("/api/v1/users", `{"name":"name 1","email":"email 1"}`).status == 201);
    auto r = c.post("/api/v1/users", `{"name":"name 2","email":"email 1"}`);
    assert(r.status == 409 && r.body == `{"detail":"a user with the same email already exists"}`, r.body);
}

/// What every `UserRepository` must do. Runs on an empty repository.
void repositoryContract(UserRepository repo)
{
    auto a = repo.add(NewUser("name 1", "email 1"));
    auto b = repo.add(NewUser("name 2", "email 2"));
    assert(b.id > a.id);
    assert(repo.find(a.id).get == a);
    assert(!repo.find(b.id + 1).has);
    assert(repo.list(10, 0) == [a, b]);
    assert(repo.list(1, 1) == [b]);
    assert(repo.list(10, 5).length == 0);

    auto changed = User(a.id, "name 3", "email 3");
    assert(repo.update(changed));
    assert(repo.find(a.id).get == changed);
    assert(!repo.update(User(b.id + 1, "name 4", "email 4")));

    bool conflict;
    try
        repo.add(NewUser("name 4", "email 2"));
    catch (Conflict)
        conflict = true;
    assert(conflict, "a taken unique value is a Conflict");

    assert(repo.remove(a.id));
    assert(!repo.remove(a.id));
    assert(repo.list(10, 0) == [b]);
}

unittest // the memory adapter
{
    repositoryContract(new MemoryUserRepository);
}

unittest // the Postgres adapter, when TEST_DATABASE_URL names a database for tests (its users table is emptied)
{
    import adapters.postgres.users : PgUserRepository;
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
    db.exec("truncate users restart identity");
    repositoryContract(new PgUserRepository(db));
}
