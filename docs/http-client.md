# Calling other HTTP APIs

`httpClient()` is an HTTP/1.1 client that waits cooperatively: inside a handler, DNS, connect, TLS, sending and reading the
response suspend only the request's fiber.

```d
import vela;

struct Quote { string currency; double rate; }

Response quote(string currency)
{
    auto r = httpClient().get("https://api.example.com/v1/quote?currency=" ~ currency);
    if (!r.ok)
        throw new HttpError(502, "the quote service failed");
    return Response(200, "application/json", r.body);
}
```

## Requests

```d
auto c = httpClient();                               // this worker's client, created on first use
auto r = c.get(url);
r = c.get(url, [HeaderPair("Authorization", "Bearer " ~ token)]);
r = c.post(url, "a=1&b=2", [HeaderPair("Content-Type", "application/x-www-form-urlencoded")]);
r = c.postJson(url, `{"name":"Ana"}`);              // Content-Type: application/json
r = c.put(url, body_);
r = c.del(url);
r = c.request("PATCH", url, headers, body_);

// binary bodies: any const(ubyte)[] (an image, a protobuf, an encrypted Web Push message)
r = c.post(endpoint, encrypted, [HeaderPair("Content-Encoding", "aes128gcm"), HeaderPair("TTL", "60")]);
r = c.put(url, imageBytes, [HeaderPair("Content-Type", "image/png")]);

// a timeout for this call only, shorter or longer than HttpClientConfig.timeout
r = c.get(url, null, 500.msecs);
r = c.post(url, body_, headers, 2.minutes);
```

Every method takes an optional last `timeout`: the deadline of that whole request (connect, send, response). Zero, the
default, means `HttpClientConfig.timeout`. Bodies are text (`const(char)[]`) or bytes (`const(ubyte)[]`); `null` is no
body.

`ClientResponse` has `status`, `headers` (`HeaderPair[]`), `body` (the whole body as a `string`), `ok` (2xx) and
`header("Name")`.

## Reading JSON

`fromJson!T` decodes a body into a type with the same rules as a request body (unknown fields ignored, required fields
checked, validation attributes applied), and `parseJson` gives a [`JsonValue`](requests.md#any-json-value-jsonvalue) when the
shape varies. Both throw `JsonError` on bad JSON, with the byte or the field:

```d
// check
import vela;

struct Rate { string currency; double rate; }

double usdRate()
{
    auto r = httpClient().get("https://api.example.com/v1/rates?base=BRL");
    if (!r.ok)
        throw new HttpError(502, "the rates service failed");
    try
    {
        foreach (rate; fromJson!(Rate[])(r.body))   // [{"currency":"USD","rate":0.19}, ...]
            if (rate.currency == "USD")
                return rate.rate;
        auto meta = parseJson(r.header("X-Meta").length ? r.header("X-Meta") : "{}");
        throw new HttpError(502, "no USD rate (" ~ meta.toString ~ ")");
    }
    catch (JsonError e)
        throw new HttpError(502, "the rates service sent bad JSON: " ~ e.msg);
}

void main()
{
    serve(() {
        auto app = new App;
        app.get!("/usd", usdRate);
        return app;
    });
}
```

`toJson(value)` turns a struct (or any JSON-serializable value) into the text for `postJson`.

## Behavior

- HTTP and HTTPS. Certificates and host names are verified against the system CAs (OpenSSL 3, loaded at run time).
- Keep-alive connections are reused per host, one pool per worker; a stale reused connection is retried once.
- Bodies are read whole, up to `maxBody` (8 MiB); streaming an upstream response is not supported yet.
- Redirects are not followed: a 3xx comes back as a response (read `r.header("Location")`).
- If the incoming request is cancelled (the client left, the deadline passed), the outgoing connection is closed.

## Errors

| Exception | When |
|-----------|------|
| `HttpClientTimeout` (a subclass of `HttpClientError`: test for it first) | `connectTimeout` or `timeout` passed |
| `HttpClientError` | DNS, connection, TLS or protocol failure; a body above `maxBody` |

Neither is an `HttpError`, so by default they become a 500. Map them in `app.onError` (a 502 or 504 is usually right):

```d
app.onError((Context ctx, Exception e) {
    if (cast(HttpClientTimeout) e) return ctx.text("upstream timed out", 504);
    if (cast(HttpClientError) e)   return ctx.text("upstream failed", 502);
    if (auto he = cast(HttpError) e) return ctx.text(he.msg, he.status);
    ctx.text("internal error", 500);
});
```

## Configuration

```d
App buildApp()
{
    HttpClientConfig cfg;
    cfg.timeout = 10.seconds;            // whole request (default 30 s)
    cfg.connectTimeout = 2.seconds;      // DNS + TCP + TLS (5 s)
    cfg.maxBody = 16 << 20;              // 8 MiB
    cfg.maxIdlePerHost = 8;
    cfg.idleTimeout = 30.seconds;
    cfg.caFile = "/etc/ssl/internal-ca.pem";   // an extra CA; empty = the system CAs only
    cfg.userAgent = "my-api/1.0";
    httpClient(cfg);                     // this worker's client from now on
    auto app = new App;
    ...
}
```

`httpClient(cfg)` replaces the worker's client, so call it once per worker: the build function is the right place.
`cfg.verifyTls = false` exists for tests only.
