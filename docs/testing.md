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
c.request(Method.DELETE, "/path");             // any method, no body

c.get("/me", hdr("Authorization", "Bearer secret"), hdr("Accept-Language", "pt"));   // headers: any number at the end
c.post("/login", "user=ana&password=x", hdr("Content-Type", "application/x-www-form-urlencoded"));
c.from("203.0.113.7").get("/whoami");          // the TCP peer address (default 127.0.0.1)
```

### JSON, forms with files, cookies

```d
// check
import andaime;
import andaime.web.testing;

struct NewUser { string name; int age; }
struct User { long id; string name; int age; }
struct Upload { string title; UploadedFile photo; }

@status(201) User create(JsonBody!NewUser u) => User(1, u.name, u.age);
string upload(Form!Upload f) => f.title ~ ":" ~ f.photo.filename;
void login(Context ctx) { setCookie(ctx, "session", "s1"); ctx.text("in"); }
string me(Cookie!"session" s) => s.value;

App buildApp()
{
    auto app = new App;
    app.post!("/users", create);
    app.post!("/upload", upload);
    app.post!("/login", login);
    app.get!("/me", me);
    return app;
}

unittest
{
    auto c = TestClient(buildApp());

    // JSON: a DTO goes out as JSON, json!T reads the answer back
    auto r = c.postJson("/users", NewUser("Ana", 31));
    assert(r.status == 201 && r.json!User == User(1, "Ana", 31));
    assert(r.json["name"].asString == "Ana");            // or as a JsonValue

    // multipart/form-data with text fields and files
    ubyte[] jpeg = [0xff, 0xd8, 0xff];
    r = c.postMultipart("/upload", [["title", "Trip"]], [TestFile("photo", "a.jpg", "image/jpeg", jpeg)]);
    assert(r.body == "Trip:a.jpg");

    // cookies kept between requests, like a browser
    c.cookies = true;
    c.post("/login", "");
    assert(c.cookie("session") == "s1" && c.get("/me").body == "s1");
}

version (unittest) {} else void main() { serve(&buildApp); }
```

- `postJson`, `putJson`, `patchJson(path, value, headers...)` send any JSON-serializable value (or JSON text as is) with
  `Content-Type: application/json`. `r.json!T` decodes the body like a request body (`JsonError` when it does not fit), and
  `r.json` gives a [`JsonValue`](requests.md#any-json-value-jsonvalue).
- `postMultipart`, `putMultipart(path, fields, files, headers...)`: `fields` are `[name, value]` pairs, `files` are
  `TestFile(field, filename, contentType, bytes)`. The boundary is chosen so it appears in no part.
- `cookies = true` turns on the jar: `Set-Cookie` values are kept and sent back to matching paths (`Path`), replaced by
  name and path, and dropped when `Max-Age` is 0 or `Expires` is past (`deleteCookie`). A `Cookie` header you pass is
  merged with the jar's. `cookie("name")` reads one, `clearCookies()` empties it. It is off by default: then read cookies
  with `r.headers("Set-Cookie")` and send them back with `hdr("Cookie", "session=...")`.

## Responses

| `TestResponse` | |
|----------------|--|
| `status`, `contentType`, `body` | |
| `header("Name")` | first value of a header, or `null` |
| `headers("Set-Cookie")` | every value of a header |
| `headerList` | all headers, in order |
| `date()` | the `Date` header andaime adds |
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
upgrade shows up in `r.status` and `r.response`. With `c.http2 = true` the client sends HTTP/2 requests, and `websocket`
opens the WebSocket as a browser does on an HTTP/2 connection (RFC 8441): a successful one answers 200 instead of 101.

## Logs

`captureLog` runs a delegate and returns the lines that `andaime.log` wrote on this thread instead of writing them to stderr
(the level and format from `configureLog` apply, so a line below the level is not collected):

```d
// check
import andaime;
import andaime.web.testing;

string boom() @safe { throw new Exception("kaput"); }

void main()
{
    auto app = new App;
    app.get!("/boom", boom);
    auto c = TestClient(app);

    auto logs = captureLog({ c.get("/boom"); });
    assert(logs[0].level == LogLevel.error && logs[0].message == "error in handler");
    assert(logs[0].field("path") == "/boom" && logs[0].has("error"));
}
```

A `CapturedLog` has `level`, `message`, `requestId`, `fields` (key and value pairs, in order), `field(key)`, `has(key)` and the
rendered `line`. Lines written by the code a [job](jobs.md) runs carry `job`, `job_id` and `attempt`, so a job test can
use `captureLog` around `drainJobs`. A real server's workers log on their own threads: use
[`setLogSink`](logging.md#sending-lines-somewhere-else-setlogsink) there.

## Tips

- Build a fresh app per test (`TestClient(buildApp())`) so tests do not share state.
- To test behind a proxy, call `app.trustProxies(["10.0.0.0/8"])` and send `X-Forwarded-For` from a trusted peer with `from`.
- Handlers that use `sleep`, `offload` or the HTTP client also work in tests: outside the server those calls simply block.
  To answer the HTTP client's calls without a network, use a
  [`FakeHttpClient`](http-client.md#testing-without-a-network-fakehttpclient).
- `TestClient` is single-threaded and runs one request at a time; for concurrency, timeouts and real sockets, start the server
  in a test (`tryServe` with `workers = 1`) and talk to it over the network.
