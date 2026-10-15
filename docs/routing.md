# Routing

## Registering routes

```d
app.get!("/users", listUsers);
app.get!("/users/{id}", getUser);
app.post!("/users", createUser);
app.put!("/users/{id}", replaceUser);
app.patch!("/users/{id}", updateUser);
app.del!("/users/{id}", deleteUser);          // `delete` is a D keyword
app.ws!("/chat/{room}", chat);                // a WebSocket: the handler returns `WebSocket` (websocket.md)
```

The handler is a function, a method of a controller (below) or a lambda; lambdas may capture variables of the build function:

```d
immutable greeting = "hello";
app.get!("/hello/{name}", (string name) => greeting ~ ", " ~ name);
```

`HEAD` is answered by the `GET` route of the same path, without the body.

Register everything inside the build function passed to `serve` ([concurrency.md](concurrency.md)). The app freezes when it
starts serving (or on the first `TestClient` request); registering anything after that throws `RouteError`.

> If your module defines its own function named `get`, `post`, `put`, `ws`... it hides vela's. Call `vela.get!("/x", fn)(app)` then.

## Path parameters

| Pattern | Matches | Handler parameter |
|---------|---------|-------------------|
| `/users/{id}` | `/users/42` | `long id` (any scalar or [text type](requests.md#your-own-types-uuids-dates-money)) |
| `/files/{*path}` | `/files/a/b/c.txt` | `string path` = `"a/b/c.txt"` (the rest of the path, at the end only) |

- Each `{name}` must match a parameter of the same name; a missing or extra one is a compile error.
- A value that does not convert (`/users/abc` for a `long`) is a 422 with `loc: ["path", "id"]`.
- Values are percent-decoded before conversion.
- Priority per segment: static text, then `{param}`, then `{*rest}`. `/users/me` wins over `/users/{id}`.
- At most 8 parameters per route. Registering the same method and pattern twice throws `RouteError`.

## Groups

A group shares a prefix and middleware:

```d
auto api = app.group("/api/v1");
api.use(&requireToken);                         // only for routes of this group
api.get!("/users", listUsers);                  // GET /api/v1/users

auto admin = api.group("/admin");               // /api/v1/admin, runs api's middleware first
admin.del!("/users/{id}", deleteUser);
```

A group prefix starts with `/`, does not end with `/` and cannot contain `{parameters}`. Middleware order is described in
[middleware.md](middleware.md).

## Controllers: handlers with state

A class whose methods carry a route attribute is registered at once with `mount`. Use it to give handlers dependencies
(a repository, a client, configuration) without globals:

```d
// check
@safe:

import vela;

struct Item { long id; string name; }

final class ItemController
{
    private Item[long] items;
    private long next = 1;

    @Get("/items/{id}")
    Item get(long id)
    {
        if (auto p = id in items) return *p;
        throw new HttpError(404, "no such item");
    }

    @Post("/items") @status(201)
    Item create(JsonBody!Item body_)
    {
        auto it = Item(next++, body_.name);
        items[it.id] = it;
        return it;
    }
}

App buildApp()
{
    auto app = new App;
    app.mount(new ItemController);      // one controller per worker: no locks needed
    return app;
}

void main() { serve(&buildApp, 8080); }
```

Attributes: `@Get`, `@Post`, `@Put`, `@Patch`, `@Delete`. The methods follow the same signature rules as free functions, and
the paths are full paths (`mount` is on `App`, not on a group).

## 404, 405 and trailing slashes

- No route for the path: **404** `{"detail":"not found"}`. Replace it with `app.onNotFound((Context ctx) { ... })`.
- The path exists for other methods: **405** `{"detail":"method not allowed"}` with an `Allow` header. Replace the body with
  `app.onMethodNotAllowed((Context ctx) { ctx.json(MyError("method not allowed"), 405); })`; `Allow` is already set.
- A trailing slash is significant by default (`TrailingSlash.strict`): `/users/` is not `/users`. `app.trailingSlash` changes it:
  - `TrailingSlash.redirect` (or `app.redirectTrailingSlash = true`): `/users/` answers **308** to `/users` (and the
    reverse) when only the other form exists. 308 keeps the method and body.
  - `TrailingSlash.matchBoth`: both forms reach the route, with no redirect (a client that does not follow a 308 on a POST
    still works). An explicit route for the other form keeps it; `{*rest}` routes already take any tail; OpenAPI shows the
    registered form only.
  - A group can choose for its own routes and subgroups: `g.trailingSlash = TrailingSlash.matchBoth` (or `strict`, under a
    `matchBoth` app). `redirect` is app-wide.

App-level middleware runs before routing, so it also sees 404 and 405 responses (an access log, CORS preflights).

## Debugging

`app.routes()` returns the route tree as text.
