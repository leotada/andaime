# Logging

`vela.log` (part of `import vela;`) writes one line per call to stderr, at four levels, in three formats. Inside a request
the request id is added by itself.

```d
// check
import vela;

struct Order { long id; string plan; }

Order create(JsonBody!Order o)
{
    logInfo("order created", "order_id", o.id, "plan", o.plan);
    if (o.plan == "trial")
        logDebug("trial order", "order_id", o.id); // written only at the debug level
    return o.value;
}

void main()
{
    configureLog(LogLevel.info, LogFormat.json); // VELA_LOG_LEVEL / VELA_LOG_FORMAT still win
    logInfo("starting", "port", 8080);
    serve(() {
        auto app = new App;
        app.use(requestId());  // the id every line of the request carries
        app.use(accessLog());
        app.post!("/orders", create);
        return app;
    });
}
```

With `LogFormat.json` a request to `/orders` writes:

```
{"time":"2026-10-14T12:00:00.123Z","level":"info","msg":"order created","request_id":"8f3a1c2e9b7d4f60","order_id":7,"plan":"pro"}
{"time":"2026-10-14T12:00:00.124Z","level":"info","msg":"request","request_id":"8f3a1c2e9b7d4f60","method":"POST","target":"/orders","status":200,"duration_us":412,"ip":"203.0.113.7"}
```

## Calls

- `logDebug`, `logInfo`, `logWarn`, `logError` take a message and then fields as pairs: `"key", value, "key", value`. A
  value is a string, a number, a `bool`, an enum, or anything `writeJson` writes (a struct, an array, a `JsonValue`),
  which goes out as JSON. `logAt(level, msg, fields...)` takes the level as a value. An odd number of fields, or a key that
  is not a string, is a one-line compile error.
- `configureLog(level, format)` sets both for the process (call it in `main`, before `serve`). `logLevel`, `logFormat`
  and `logEnabled(level)` read them.

## Levels and formats

| Level | |
|-------|-|
| `LogLevel.debug_` | details for development (`debug` is a D keyword) |
| `LogLevel.info` | the default: the access log, your events |
| `LogLevel.warn` | something to look at |
| `LogLevel.error` | failures: vela's exceptions behind a 500, `vela.jobs:` failures |
| `LogLevel.off` | nothing |

| Format | A line |
|--------|--------|
| `LogFormat.text` (default) | `order created request_id=8f3a order_id=7 plan=pro`; vela's own lines are exactly as before (`GET /orders 200 0.4ms ip=...`, `vela: error in GET /x: ...`) |
| `LogFormat.kv` | `time=2026-10-14T12:00:00.123Z level=info msg="order created" request_id=8f3a order_id=7 plan=pro` (logfmt) |
| `LogFormat.json` | one JSON object per line, with the same keys |

Text values that are not a plain word are quoted and escaped like JSON strings, so a stack trace stays on one line in
`kv` and `json`. Time is UTC with milliseconds.

The environment overrides the code, so a deployment can change them without a rebuild: `VELA_LOG_LEVEL` (`debug`, `info`,
`warn`, `error`, `off`) and `VELA_LOG_FORMAT` (`text`, `kv` or `logfmt`, `json`).

## The request id

The `requestId()` middleware gives each request an id (the client's `X-Request-Id` when it is safe, or a new one), and
every line written while that request runs carries it as `request_id`, from any function, without passing a `Context`
around. vela keeps the id with the request's fiber, so lines of requests that interleave on one worker (while one waits on
the database, another runs) never get each other's id. Outside a request (startup, a background job) there is no
`request_id`.

## vela's own lines

The access log (`accessLog()`, `info`), the exceptions behind a 500 (`error`, with the stack trace, rate-limited by
`App.logStackTraces`) and the failures of background jobs (`vela.jobs:`, `error`) go through `vela.log`: they follow the
level, and in `kv`/`json` they are structured (`msg="error in handler" method=GET path=/x error="..."`). A few startup and
engine messages (bad configuration, a stalled worker, a crash) are still written straight to stderr.

## Cost

A line below the level costs two memory loads and allocates nothing. A written line is built in a buffer reused by the
thread and goes out with one `write(2)`, so lines of different workers do not interleave; after the first lines it
allocates nothing either (`tests/alloc/log_hot_path.d` checks both).
