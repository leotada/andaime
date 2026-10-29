# Calling other HTTP APIs

`httpClient()` is an HTTP/1.1 client that waits cooperatively: inside a handler, DNS, connect, TLS, sending and reading the
response suspend only the request's fiber.

```d
import andaime;

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
import andaime;

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
- Bodies are read whole, up to `maxBody` (8 MiB); for larger ones, see [large bodies](#large-bodies-open-and-bodysource).
- Redirects are not followed: a 3xx comes back as a response (read `r.header("Location")`).
- If the incoming request is cancelled (the client left, the deadline passed), the outgoing connection is closed.
- A stale pooled connection is retried only for idempotent methods (GET, HEAD, PUT, DELETE, OPTIONS), never a POST.

## Large bodies: `open` and `BodySource`

A file to download or upload does not need to fit in memory. `open` returns the response once its head arrived and
hands the body over as it comes (`maxBody` does not apply); a `BodySource` sends a body in pieces:

```d
// check
@safe:

import andaime;
import std.stdio : File;

void download(string url, string dest)
{
    auto s = httpClient().open("GET", url);
    scope (exit) s.close();              // the connection goes back to the pool only if the body was read to the end
    if (!s.ok)
        throw new Exception("download failed");
    auto f = File(dest, "wb");
    ubyte[64 << 10] buf;
    size_t n;
    while ((n = s.read(buf[])) > 0)
        f.rawWrite(buf[0 .. n]);
}

void upload(string url, string path, ulong size)
{
    auto body = BodySource(size, (scope sink) {
        auto f = File(path, "rb");
        auto buf = new ubyte[64 << 10];
        for (auto got = f.rawRead(buf); got.length; got = f.rawRead(buf))
            sink(got);
    });
    auto r = httpClient().put(url, body, [HeaderPair("Content-Type", "application/octet-stream")]);
}
```

- `s.status`, `s.headers`, `s.header(name)` and `s.contentLength` (-1 when the server did not announce it) are ready
  when `open` returns; `read` returns 0 at the end. Content-Length, chunked and until-close bodies.
- `timeout` bounds the connection and the request head; after it, **each** wait (a piece sent, the response head, a
  piece of the body) has a `timeout` of its own, since the pace may be the client's you pass the body on to. The same
  holds for `request`/`put`/`post` with a `BodySource`.
- A `BodySource` announces its `length` (sent as `Content-Length`); writing more or fewer bytes fails the request.
  `write` may be called again when a stale pooled connection is retried, so it starts from the beginning each time.
- An upload received as `SpooledFile` is passed on with `file.bodySource()`, within the request.
- `FakeHttpClient` serves both: a `BodySource` is recorded whole in `requests[i].body_`, and `open` reads the
  scripted reply in pieces.

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

## Testing without a network: `FakeHttpClient`

Code that calls `httpClient()` (an S3 upload, a mail API, a payment provider) can be tested without a server. A
`FakeHttpClient` answers every request of every `HttpClient` on its thread with replies you script, and records the requests:

```d
// check
import andaime;

bool uploadAvatar(long id, const(ubyte)[] png)
{
    import std.conv : to;

    auto r = httpClient().put("https://bucket.s3.example.com/avatars/" ~ id.to!string ~ ".png", png,
        [HeaderPair("Content-Type", "image/png")]);
    return r.ok;
}

unittest
{
    auto fake = new FakeHttpClient;
    fake.expect("PUT", "https://bucket.s3.example.com/avatars/*").respond(200).respond(503); // two calls, in order
    fake.expect("POST", "https://api.mail.example/send").timeout();
    fake.install();
    scope (exit) fake.uninstall();

    immutable ubyte[] png = [0x89, 'P', 'N', 'G'];
    assert(uploadAvatar(1, png));
    assert(!uploadAvatar(2, png));
    assert(fake.requests[0].url == "https://bucket.s3.example.com/avatars/1.png");
    assert(fake.requests[0].body_ == png && fake.requests[0].header("content-type") == "image/png");

    bool timedOut;
    try
        httpClient().post("https://api.mail.example/send", `{"to":"a@x.com"}`);
    catch (HttpClientTimeout)
        timedOut = true;
    assert(timedOut);
    fake.verify(); // every expected request was made
}

void main() {}
```

- `expect(method, url)` matches the method and the whole URL, or a prefix when the URL ends in `*`. Expectations are tried
  in order. Each answers as many requests as it has replies: `respond(status, body, headers)`, `timeout()`
  (`HttpClientTimeout`) or `fail(msg)` (`HttpClientError`); one with no reply answers once with a 200. `always()` repeats
  the last reply forever.
- A request no expectation matches throws `HttpClientError("andaime.http: FakeHttpClient: unexpected request ...")`, so a
  forgotten call fails the test instead of reaching the network. Every request, expected or not, lands in `requests`
  (method, URL, headers, the body as bytes, `text`, the per-call timeout). `verify()` throws if an expectation was not used
  up.
- `install` routes this thread's clients (the worker's `httpClient()` and any `new HttpClient`) until `uninstall`. In a
  server started by a test, install the fake from the build function: it runs on each worker's thread. The real client pays
  one thread-local null check per request.
- `setHttpTransport(t)` installs any other `HttpTransport` (a recording proxy, say).
