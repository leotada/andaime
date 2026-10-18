/// {{PluralWords}}: the API end to end over in-memory adapters, and the repository contract on each adapter.
module tests.{{plural}};

@safe:

import andaime;
import andaime.web.testing;
import app : buildAppWith, memoryAdapters;
{{#hasUnique}}
import domain.errors : Conflict;
{{/hasUnique}}
import domain.{{plural}};
import usecases.{{plural}};
import adapters.memory.{{plural}} : Memory{{Name}}Repository;

unittest // create, read, list, replace and delete through HTTP
{
    auto c = TestClient(buildAppWith(memoryAdapters()));

    auto r = c.post("/api/v1{{path}}", `{{body1}}`);
    assert(r.status == 201, r.body);
    assert(r.body == `{{out1}}`, r.body);

    r = c.get("/api/v1{{path}}/1");
    assert(r.status == 200 && r.body == `{{out1}}`, r.body);

    r = c.get("/api/v1{{path}}?limit=10");
    assert(r.status == 200 && r.body == `[{{out1}}]`, r.body);

    r = c.put("/api/v1{{path}}/1", `{{body2}}`);
    assert(r.status == 200 && r.body == `{{out2}}`, r.body);

    r = c.del("/api/v1{{path}}/1");
    assert(r.status == 204, r.body);

    r = c.get("/api/v1{{path}}/1");
    assert(r.status == 404 && r.body == `{"detail":"{{words}} not found"}`, r.body);
}

unittest // {{#hasRequired}}a body without its fields and {{/hasRequired}}a bad page {{#hasRequired}}are{{/hasRequired}}{{^hasRequired}}is{{/hasRequired}} 422{{#hasUnique}}; a taken unique value is 409{{/hasUnique}}
{
    auto c = TestClient(buildAppWith(memoryAdapters()));
{{#hasRequired}}
    assert(c.post("/api/v1{{path}}", `{}`).status == 422);
{{/hasRequired}}
    assert(c.get("/api/v1{{path}}?limit=0").status == 422);
{{#hasUnique}}
    assert(c.post("/api/v1{{path}}", `{{body1}}`).status == 201);
    auto r = c.post("/api/v1{{path}}", `{{conflictBody}}`);
    assert(r.status == 409 && r.body == `{"detail":"{{a}} {{words}} with the same {{uniqueText}} already exists"}`, r.body);
{{/hasUnique}}
}

/// What every `{{Name}}Repository` must do. Runs on an empty repository.
void repositoryContract({{Name}}Repository repo)
{
    auto a = repo.add(New{{Name}}({{args1}}));
    auto b = repo.add(New{{Name}}({{args2}}));
    assert(b.id > a.id);
    assert(repo.find(a.id).get == a);
    assert(!repo.find(b.id + 1).has);
    assert(repo.list(10, 0) == [a, b]);
    assert(repo.list(1, 1) == [b]);
    assert(repo.list(10, 5).length == 0);

    auto changed = {{Name}}(a.id, {{args3}});
    assert(repo.update(changed));
    assert(repo.find(a.id).get == changed);
    assert(!repo.update({{Name}}(b.id + 1, {{args4}})));
{{#hasUnique}}

    bool conflict;
    try
        repo.add(New{{Name}}({{conflictArgs}}));
    catch (Conflict)
        conflict = true;
    assert(conflict, "a taken unique value is a Conflict");
{{/hasUnique}}

    assert(repo.remove(a.id));
    assert(!repo.remove(a.id));
    assert(repo.list(10, 0) == [b]);
}

unittest // the memory adapter
{
    repositoryContract(new Memory{{Name}}Repository);
}
{{#pg}}

unittest // the Postgres adapter, when TEST_DATABASE_URL names a database for tests (its {{table}} table is emptied)
{
    import adapters.postgres.{{plural}} : Pg{{Name}}Repository;
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
    db.exec("truncate {{table}} restart identity");
    repositoryContract(new Pg{{Name}}Repository(db));
}
{{/pg}}
