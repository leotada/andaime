/// {{app}}: the routes, their handlers and their tests.
module app;

@safe:

import andaime;

struct Item
{
    long id;
    string name;
}

struct NewItem
{
    string name;
}

private Item[] items; // module state is thread-local in D: this worker's items
private long lastId;

Item[] listItems() => items;

Item getItem(long id)
{
    foreach (item; items)
        if (item.id == id)
            return item;
    throw new HttpError(404, "item not found");
}

@status(201)
Item createItem(JsonBody!NewItem body_)
{
    auto item = Item(++lastId, body_.name);
    items ~= item;
    return item;
}

App buildApp()
{
    auto app = new App;
    app.get!("/items", listItems);
    app.get!("/items/{id}", getItem);
    app.post!("/items", createItem);
    app.serveOpenApi(OpenApiInfo("{{app}}", "0.1.0"));
    return app;
}

unittest
{
    import andaime.web.testing;

    auto c = TestClient(buildApp());
    auto r = c.post("/items", `{"name":"first"}`);
    assert(r.status == 201 && r.body == `{"id":1,"name":"first"}`, r.body);
    assert(c.get("/items").body == `[{"id":1,"name":"first"}]`);
    assert(c.get("/items/2").status == 404);
}
