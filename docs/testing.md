# Testing

`TestClient` runs requests through an `App` in memory: no sockets, no server, no ports. Routing, parameter extraction,
validation, middleware, error handling and response checks are the same code the server runs, so a test sees what a client
would see.

```d
unittest
{
    auto c = TestClient(buildApp());

    auto r = c.post("/users", `{"name":"Ana","age":31}`);
    assert(r.status == 201, r.body);
    assert(r.contentType == "application/json");
    assert(r.body == `{"id":1,"name":"Ana","age":31,"email":null}`, r.body);

    r = c.get("/users/abc");
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"int_parsing","loc":["path","id"],`
        ~ `"msg":"expected an integer between -9223372036854775808 and 9223372036854775807"}]}`);
}
```

Run them with `dub test`. If the tests live in the same module as `main`, keep `main` out of the test build:

```d
version (unittest) {} else
void main() { serve(&buildApp, 8080); }
```

## Requests

```d
c.get("/path?query=1");
c.post("/path", body_);
c.put("/path", body_);
c.patch("/path", body_);
c.del("/path");
c.head("/path");
c.options("/path");
c.request(Method.POST, "/path", body_, headers...);

c.get("/me", hdr("Authorization", "Bearer secret"), hdr("Accept-Language", "pt"));   // headers: any number at the end
c.post("/login", "user=ana&password=x", hdr("Content-Type", "application/x-www-form-urlencoded"));
c.from("203.0.113.7").get("/whoami");          // the TCP peer address (default 127.0.0.1)
```

`TestClient` does not keep cookies between requests: read them with `r.headers("Set-Cookie")` and send them back with
`hdr("Cookie", "session=...")`.

## Responses

| `TestResponse` | |
|----------------|--|
| `status`, `contentType`, `body` | |
| `header("Name")` | first value of a header, or `null` |
| `headers("Set-Cookie")` | every value of a header |
| `headerList` | all headers, in order |
| `date()` | the `Date` header vela adds |
| `chunks` | the body as it was written: one entry per `write` of a [stream](streaming.md) (one per Server-Sent Event) |
| `contentLength` | the announced length, -1 for a stream of unknown length |
| `aborted` | a stream failed after it started (a real client would see a cut-off body) |

## WebSockets

`websocket(path, script, headers...)` plays a script of client frames to a [WebSocket route](websocket.md#testing) and returns
what the server sent:

```d
auto r = c.websocket("/chat/a", WsScript().text("hi").ping("p").close(), hdr("Authorization", "Bearer secret"));
assert(r.status == 101 && r.texts == ["a: hi"] && r.pongs == ["p"] && r.closeCode == 1000);
```

`WsScript` has `text`, `binary`, `continuation`, `ping`, `close` and `raw` (any bytes, to test the server's checks). A refused
upgrade shows up in `r.status` and `r.response`.

## Tips

- Build a fresh app per test (`TestClient(buildApp())`) so tests do not share state.
- To test behind a proxy, call `app.trustProxies(["10.0.0.0/8"])` and send `X-Forwarded-For` from a trusted peer with `from`.
- Handlers that use `sleep`, `offload` or the HTTP client also work in tests: outside the server those calls simply block.
- `TestClient` is single-threaded and runs one request at a time; for concurrency, timeouts and real sockets, start the server
  in a test (`tryServe` with `workers = 1`) and talk to it over the network.
