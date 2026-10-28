# Responses

## What a handler returns

| Return type | Response |
|-------------|----------|
| `void` | 204 No Content |
| `string` | 200, `text/plain; charset=utf-8` |
| a struct, an array, a map `V[string]`, a number, a `bool` | 200, `application/json` |
| `WithStatus!T` | `T` as above, with the status you pick: `return withStatus(201, user);` |
| `Response` | full control: status, content type, body, extra headers |
| `Stream`, `EventStream` | a body sent while it is produced ([streaming.md](streaming.md)) |

Throwing `new HttpError(status, "message")` answers that status with `{"detail":"message"}`; any other exception is a 500
(logged with its stack trace). See [middleware.md](middleware.md#error-handling) to change that.

## Status codes

`@status` sets the success status of a handler; OpenAPI documents it:

```d
@status(201) @responds(409, "e-mail already registered")
User createUser(JsonBody!NewUser body_) { ... }       // answers 201

@status(202) void startJob() { ... }                  // a void handler answers 202 instead of 204
```

`@responds(code, "description")` only documents an error (the handler still throws `HttpError`). A handler that returns
`WithStatus` or `Response` decides its status at run time.

## JSON

Structs, arrays and maps are written as JSON:

- Field names are the D names; `@jsonKey("name")` renames, `@naming(Naming.snakeCase)` on the struct renames all of them
  ([wire names](requests.md#wire-names-naming-and-wirename)), `@jsonIgnore` skips.
- An empty `Optional!T` is `null`, unless the field (or its struct) has `@omitIfAbsent`: then the key is left out and
  OpenAPI drops `nullable` from the field. An `enum` is its member name (or its wire name). A [text type](requests.md#your-own-types-uuids-dates-money)
  is a JSON string.
- Floating point is written with 17 significant digits (it reads back exactly); NaN and infinities are written as `null`.

## `Response`: full control

```d
Response download() => Response(200, "text/csv", "id,name\n1,Ana\n", [HeaderField("Content-Disposition", "attachment")]);
Response page() => Response.html("<h1>hello</h1>");
Response legacy() => Response.redirect("/new-place", 308);     // 307 by default
Response plain() => Response.text("not here", 404);
```

## Headers

Through a `Context` parameter (in a handler or middleware):

```d
ctx.setHeader("Cache-Control", "no-store");    // replaces a header of that name
ctx.addHeader("Link", "</a.css>; rel=preload"); // appends (repeatable headers)
ctx.addVary("Accept-Language");                 // merges into one Vary header
```

andaime checks every header after the middleware has unwound. A CR, LF, NUL or other control character in a name or value, an
invalid name, or more than 32 headers turns the response into a **500** with a log line naming the header (never its value),
so a header-injection bug cannot reach the client. `Content-Length`, `Connection`, `Keep-Alive`, `Transfer-Encoding`, `Upgrade`,
`Proxy-Connection` and `TE` belong to andaime and are dropped if you set them; `Date` is added unless you set it.

## Cookies

```d
void login(Context ctx, Form!Login f)
{
    auto token = authenticate(f.user, f.password);
    CookieOptions opts;
    opts.maxAge = Optional!long(7 * 86_400);    // a week, in seconds
    ctx.setCookie("session", token, opts);
}

void logout(Context ctx) { ctx.deleteCookie("session"); }

string theme(Context ctx) => ctx.cookie("theme").idup;     // read without a parameter (a view: copy to keep)
```

`CookieOptions` defaults are the safe ones: `Path=/`, `Secure`, `HttpOnly`, `SameSite=Lax`. Fields: `path`, `domain`, `maxAge`
(seconds; 0 deletes), `expires` (Unix time), `secure`, `httpOnly`, `sameSite` (`SameSite.lax`, `.strict`, `.none`). For local
development over plain `http://` pass `secure: false`, or the browser will not send the cookie back. Several `setCookie` calls
produce several `Set-Cookie` headers. An invalid name or value is a programming error and answers 500.

To read a cookie as a parameter, see [requests.md](requests.md#headers-and-cookies).

## Writing to the response directly

Middleware and `Context` handlers can also write the response by hand: `ctx.text("message", 418)` sets status, content type
and body; `ctx.response.status`, `ctx.response.contentType` and `ctx.response.body.put(...)` are the pieces.
