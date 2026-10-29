# Streaming responses

Return a `Stream` when the body is produced while it is sent (an export, a large download), or an `EventStream` for
Server-Sent Events (live updates, token-by-token output).

```d
// check
@safe:

import andaime;
import core.time : seconds;

string[] rowsOf(string table) => ["id,name\n", "1,Ana\n"];

Stream export_(string table)
{
    return Stream("text/csv", (scope StreamWriter w) {
        foreach (row; rowsOf(table))
            w.write(row);              // sent as it is written; waits if the client is slow
    });
}

EventStream clock()
{
    return EventStream((scope EventWriter w) {
        foreach (i; 0 .. 60)
        {
            w.send("tick");            // "data: tick" and a blank line, flushed at once
            sleep(1.seconds);          // the fiber waits; the worker serves other requests
        }
    });
}

App buildApp()
{
    auto app = new App;
    app.get!("/export/{table}", export_);
    app.get!("/clock", clock);
    return app;
}

void main() { serve(&buildApp, 8080); }
```

```sh
curl -N localhost:8080/clock           # one event per second
```

A browser reads Server-Sent Events with `new EventSource("/clock")`. Named events and ids: `w.send(data, "price", "42")`.

## Contract

- A handler may return `Stream`, `EventStream` or `WithStatus!Stream`; `@status(202)` also applies. `Stream.contentLength` (optional)
  announces an exact length (used for files); otherwise HTTP/1.1 sends the body chunked (HTTP/1.0 clients get a body that ends
  when the connection closes) and HTTP/2 uses DATA frames.
- The body runs inside the middleware chain. The head (status, headers) is committed lazily, on the first `write`/`flush` (or
  when the body returns). A handler that throws before that gets an ordinary error response; after it, the response is aborted
  (HTTP/1.1: connection closed without the final chunk, HTTP/2: `RST_STREAM(INTERNAL_ERROR)`) and the error is logged. Headers
  set after the commit are ignored, with one log line.
- HEAD gets the head only: the body does not run. `TestClient` records one chunk per `write` (`response.chunks`).
- `Stream.done` (optional) runs once when the response ends, whether the body ran, failed or did not run (HEAD): close
  there what the body reads, such as a file or an upstream download (`Stream(type, body, length, () { s.close(); })`).
- `EventWriter.send(data, event, id)`: several lines of `data` become several `data:` lines; a CR or LF in the event name or id
  aborts the stream. `comment()` is a heartbeat, `retry(ms)` tells the browser when to reconnect. `Cache-Control: no-cache` and
  `X-Accel-Buffering: no` are set for you.
- `@produces("text/csv")` tells OpenAPI the media type of a `Stream`.

## Backpressure, cancellation and limits

- `write` hands data to the connection. Past `ServerConfig.streamHighWaterBytes` (64 KiB) it waits for the transport: the socket
  on HTTP/1.1, the flow-control windows and the stream's own buffer on HTTP/2. A reader that makes no progress for
  `writeTimeoutMs` is dropped.
- A client that leaves cancels the handler: the next `write`, `flush` or `sleep` throws `RequestCancelled` and `scope(exit)` runs.
- `requestTimeoutMs` ends when the response starts; `streamTimeoutMs` (default 0 = none) bounds the whole stream.
- A stream holds a fiber and counts toward `maxInFlight` (1,024 per worker by default). Graceful stop cancels streams still open
  after `shutdownGraceMs`.
- Static files above `StaticConfig.offloadAbove` (256 KiB) are streamed in `chunkBytes` (64 KiB) pieces with a `Content-Length`;
  each piece is read through `offload`. `maxFileBytes` (1 GiB) is a safety cap.

## Behind a proxy

nginx honors the `X-Accel-Buffering: no` header andaime sends on an `EventStream`. Other proxies have their own switch for response
buffering or flushing (Caddy's `reverse_proxy` has `flush_interval -1`). Send a heartbeat (`w.comment()`) more often than the
proxy's idle timeout.
