# Configuration reference

`ServerConfig` (passed to `serve(&buildApp, cfg)`). Times are milliseconds, sizes bytes.

| Field | Default | Meaning |
|-------|---------|---------|
| `host`, `port` | `0.0.0.0`, 8080 | listener |
| `workers` | 0 | 0 = one per core. Each worker builds its own App ([concurrency.md](concurrency.md#workers-and-state)) |
| `backlog` | 1024 | listen backlog |
| `maxConnections` | 10,000 | per worker |
| `maxInFlight` | 1,024 | requests (and streams, and open WebSockets) in progress per worker; above it 503 + `Retry-After` (`REFUSED_STREAM` on h2) |
| `maxIdleWorkers` | 64 | idle fibers kept; the rest are torn down |
| `fiberStackBytes` | 256 KiB | virtual stack per fiber; an overflow is a SIGSEGV that ends the process (the message names the request) |
| `headerTimeoutMs` | 10,000 | first byte to end of head (slowloris); also the no-progress limit while a chunked or streamed body arrives |
| `bufferBodyBytes` | 256 KiB | a request body above it is handed over unread (one with a length at once, a chunked or unannounced HTTP/2 one once that much arrived): a `BodyStream` or `SpooledFile` route reads it as it arrives, any other route gets it read whole first (see [requests.md](requests.md#large-uploads-spooledfile-and-bodystream)); 0 = always buffer |
| `minBodyRate` | 240 | bytes/s: a body arriving slower than this on average, once `minBodyRateGraceMs` passed, ends with 408 (a trickle that `headerTimeoutMs` cannot catch). Only time spent waiting for the client counts, so a slow handler is never blamed. Checked for streamed bodies and chunked ones being buffered; 0 = off |
| `minBodyRateGraceMs` | 5,000 | waiting time before `minBodyRate` applies |
| `idleTimeoutMs` | 60,000 | idle keep-alive |
| `requestTimeoutMs` | 30,000 | until the handler starts the response; past it the request is cancelled (504) |
| `writeTimeoutMs` | 30,000 | a client that does not read; also each blocked write of a streamed response |
| `streamHighWaterBytes` | 64 KiB | buffered bytes at which a streaming `write` goes out and waits for the transport; also the bytes queued for a WebSocket above which `send` waits |
| `streamTimeoutMs` | 0 | whole-stream limit; 0 = none |
| `trustedProxies`, `forwardedHeader` | none, `X-Forwarded-For` | proxies whose forwarding header is believed (CIDR strings) |
| `shutdownGraceMs` | 10,000 | wait for in-flight work on stop |
| `stallWarnMs` | 50 | log a handler that holds the worker this long without yielding; 0 = off |
| `reusePort` | true | `SO_REUSEPORT`: one listener per worker |
| `trimAfterBurst` | true | after a burst and a quiet second: retire idle fibers, drop the buffer cache and collect, returning memory to the OS |
| `trimHeapGrowthBytes` | 32 MiB | with `trimAfterBurst`, the same cleanup after a quiet second when the GC heap grew this much since the last one: a few large requests (uploads, reports) give their memory back too, not only a burst of many; 0 = bursts only |
| `http2`, `http2MaxStreams`, `http2StreamWindowBytes`, `http2ConnectionWindowBytes` | true, 100, 256 KiB, 1 MiB | see [http2.md](http2.md) |
| `http2WebSockets` | true | WebSockets as HTTP/2 streams (RFC 8441); false: browsers open an HTTP/1.1 connection for each, see [websocket.md](websocket.md#http2) |
| `tls` (`certFile`, `keyFile`, `reloadCheckMs`, `redirectPort`, `acmeWebroot`) | off | see [tls.md](tls.md) |
| `logConnectionErrors` | true | log failed handshakes and HTTP/2 connection errors (rate-limited) |
| `limits` (`maxHeadBytes`, `maxTargetBytes`, `maxBodyBytes`) | 8 KiB, 4 KiB, 1 MiB | request size limits (431, 414, 413) |
| `errorBodies` | none | bodies of the HTTP/1.1 answers the engine gives before any handler runs (400, 408, 413, 414, 431, 501, 503, 505), as `ErrorBody(status, body, contentType, replyStatus, accept)` entries; `cfg.errorBodies = jsonErrorBodies();` sends `{"detail":"..."}` like the app's 404 and 405. `replyStatus` (0: keep) sends another status, for an older contract (`ErrorBody(431, body, "application/json", 413)`). `accept` (a media range) uses the entry only for requests whose `Accept` takes it: the first entry the request names wins, then the first it takes through a wildcard, then the first without `accept` (JSON for an API client, HTML for a browser). HTTP/2 and the development server send these without a body |

Other settings: `StaticConfig` (`serveStatic`), `OpenApiInfo` (`serveOpenApi`), `CorsConfig` (`cors`), `CookieOptions`
(`setCookie`), `PgConfig` (`andaime:pg`), `HttpClientConfig`, `App.logStackTraces`, `App.trailingSlash` ([routing.md](routing.md)),
`configureLog(level, format)` and the `ANDAIME_LOG_LEVEL` / `ANDAIME_LOG_FORMAT` environment variables ([logging.md](logging.md)),
`ANDAIME_ROUTES=1` (print the route table and return from `serve` without serving, [routing.md](routing.md#debugging)), `ANDAIME_OPENAPI=1` (the same with the OpenAPI document, [static-files-and-openapi.md](static-files-and-openapi.md#the-document-as-a-file-for-a-typed-frontend)). Process-level
variables of the tests and tools (`ANDAIME_STRICT`, `ANDAIME_CI`, `ANDAIME_PG`, `ANDAIME_TLS_RSS_MB`...) are described in `tools/check.sh`.

`LoopStats` (per worker, for metrics and tests): `inFlight`, `peakInFlight`, `connections`, `rejected`, `cancelled`, `timedOut`,
`stalls`, `handlerErrors`, `fibersPoisoned`, `http2Connections`, `http2Streams`, `tlsHandshakes`, `tlsFailures`, `webSockets`,
`webSocketsTotal`...
