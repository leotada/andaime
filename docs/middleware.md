# Middleware and error handling

## Writing middleware

A middleware is a function (or delegate) `void(Context ctx, Next next)`. It runs code before the handler, calls `next()`, and
runs code after. Not calling `next()` stops the request there:

```d
void timing(Context ctx, Next next)
{
    immutable t0 = MonoTime.currTime;
    next();                                              // the rest of the chain and the handler
    // the response is ready here: ctx.response.status is set
    ctx.setHeader("Server-Timing", serverTiming(MonoTime.currTime - t0));
}

void requireJson(Context ctx, Next next)
{
    if (ctx.request.method == Method.POST && ctx.request.header("Content-Type") != "application/json")
        throw new HttpError(415, "send JSON");           // or ctx.text("send JSON", 415) and return
    next();
}

app.use(&timing);
app.use(&requireJson);
app.use((Context ctx, Next next) { next(); });           // a lambda works too, and may capture variables
```

## Order

- `app.use` middleware runs for **every request**, before routing, so it also sees 404, 405 and CORS preflights.
- `group.use` middleware runs only for the routes of that group, after the app's middleware and after its parent group's.
- Within one App or group, the first `use` is the outermost layer.
- Registration order relative to routes does not matter: a middleware applies to every route of its App or group, including
  routes added before it.

## Passing data to handlers: `ctx.locals` and `Local!T`

A middleware stores a typed value for this request; a handler declares it as a parameter:

```d
struct Caller { string userId; }

auto api = app.group("/api");
api.use((Context ctx, Next next) {
    auto token = bearerToken(ctx);                       // "" when there is no "Authorization: Bearer ..."
    if (token.length == 0)
    {
        ctx.setHeader("WWW-Authenticate", "Bearer");
        throw new HttpError(401, "missing token");
    }
    ctx.locals.set(Caller(lookupUser(token)));
    next();
});

string whoAmI(Local!Caller c) => c.userId;               // the handler receives the value
api.get!("/me", whoAmI);
```

One value per type, up to 8 types per request. `ctx.locals.find!T()` returns a pointer, or `null` when nothing was stored. A
handler that asks for a `Local!T` nobody set gets a 500 (a configuration error, not the client's).

## Ready-made middleware

| | |
|-|-|
| `accessLog()` | one line per request through [`andaime.log`](logging.md) at the `info` level: `GET /users/7 200 1.3ms ip=203.0.113.7 rid=...` by default, structured fields in the `kv` and `json` formats; register it after `requestId()` to include the id |
| `requestId(header = "X-Request-Id")` | reuses a safe incoming id or generates one; echoes it in the response; handlers read it as `Local!RequestId` |
| `cors(CorsConfig(...))` | CORS, preflights included (below) |

### CORS

```d
app.use(cors(CorsConfig(["https://app.example.com"])));           // these origins
app.use(cors(CorsConfig(["*"])));                                 // any origin, without cookies

CorsConfig c;
c.origins = ["https://app.example.com"];
c.methods = "GET, POST, PUT, DELETE";                             // the default also has HEAD and PATCH
c.allowHeaders = "Authorization, Content-Type";                   // empty = whatever the browser asks for
c.exposeHeaders = "X-Request-Id";                                 // response headers JavaScript may read
c.credentials = true;                                             // cookies / Authorization
c.maxAgeSeconds = 600;                                            // preflight cache
app.use(cors(c));
```

Register CORS with `app.use` (not on a group), so it can answer the `OPTIONS` preflight of any route. `Vary: Origin` is set
whenever the answer depends on the origin.

## Error handling

Without an error handler:

- `HttpError(status, msg)` answers `status` with `{"detail":"msg"}`.
- Any other `Exception` answers 500 `{"detail":"internal error"}` and is logged with its stack trace (at most 5 traces per
  second per App; `app.logStackTraces = false` turns them off).
- An `Error` (a `RangeError`, a failed `assert`...) also answers 500 and is logged with a full trace; the fiber that ran it is
  retired because cleanup may not have run. The server keeps serving.

`app.onError` takes over for every exception from handlers and middleware, for example to map library errors to statuses:

```d
app.onError((Context ctx, Exception e) {
    if (auto he = cast(HttpError) e)
        return ctx.text(he.msg, he.status);
    if (auto pe = cast(PgError) e)
        if (pe.isUniqueViolation)
            return ctx.text("already exists", 409);
    ctx.text("internal error", 500);       // exceptions that are not HttpError were already logged
});

app.onNotFound((Context ctx) { ctx.text("nothing here", 404); });
app.onMethodNotAllowed((Context ctx) { ctx.text("wrong method", 405); }); // the Allow header is already set
```

Middleware sees the final status after `next()` returns, even when the handler threw: the error has already been turned into
a response (by `onError`, or the default). Map errors in `onError`, not with a `try`/`catch` around `next()`.

`RequestCancelled` (the client left, or the deadline passed) is not an `Exception`, so `catch (Exception)` does not swallow
it; `scope(exit)` blocks still run ([concurrency.md](concurrency.md#cancellation)).
