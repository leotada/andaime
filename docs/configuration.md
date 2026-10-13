# Configuration reference

`ServerConfig` (passed to `serve(&buildApp, cfg)`). Times are milliseconds, sizes bytes.

| Field | Default | Meaning |
|-------|---------|---------|
| `host`, `port` | `0.0.0.0`, 8080 | listener |
| `workers` | 0 | 0 = one per core. Each worker builds its own App ([quickstart](quickstart.md), "Workers and state") |
| `backlog` | 1024 | listen backlog |
| `maxConnections` | 10,000 | per worker |
| `maxInFlight` | 1,024 | requests (and streams) in progress per worker; above it 503 + `Retry-After` (`REFUSED_STREAM` on h2) |
| `maxIdleWorkers` | 64 | idle fibers kept; the rest are torn down |
| `fiberStackBytes` | 256 KiB | virtual stack per fiber; an overflow is a SIGSEGV that ends the process (the message names the request) |
| `headerTimeoutMs` | 10,000 | first byte to end of head (slowloris); also the no-progress limit while a chunked body arrives |
| `idleTimeoutMs` | 60,000 | idle keep-alive |
| `requestTimeoutMs` | 30,000 | until the handler starts the response; past it the request is cancelled (504) |
| `writeTimeoutMs` | 30,000 | a client that does not read; also each blocked write of a streamed response |
| `streamHighWaterBytes` | 64 KiB | buffered bytes at which a streaming `write` goes out and waits for the transport |
| `streamTimeoutMs` | 0 | whole-stream limit; 0 = none |
| `trustedProxies`, `forwardedHeader` | none, `X-Forwarded-For` | proxies whose forwarding header is believed (CIDR strings) |
| `shutdownGraceMs` | 10,000 | wait for in-flight work on stop |
| `stallWarnMs` | 50 | log a handler that holds the worker this long without yielding; 0 = off |
| `reusePort` | true | `SO_REUSEPORT`: one listener per worker |
| `trimAfterBurst` | true | after a burst and a quiet second: retire idle fibers, drop the buffer cache and collect, returning memory to the OS |
| `http2`, `http2MaxStreams`, `http2StreamWindowBytes`, `http2ConnectionWindowBytes` | true, 100, 256 KiB, 1 MiB | see [http2.md](http2.md) |
| `tls` (`certFile`, `keyFile`, `reloadCheckMs`, `redirectPort`, `acmeWebroot`) | off | see [tls.md](tls.md) |
| `logConnectionErrors` | true | log failed handshakes and HTTP/2 connection errors (rate-limited) |
| `limits` (`maxHeadBytes`, `maxTargetBytes`, `maxBodyBytes`) | 8 KiB, 4 KiB, 1 MiB | request size limits (431, 414, 413) |

Other settings: `StaticConfig` (`serveStatic`), `OpenApiInfo` (`serveOpenApi`), `CorsConfig` (`cors`), `CookieOptions`
(`setCookie`), `PgConfig` (`vela-pg`), `HttpClientConfig`, `App.logStackTraces`, `App.redirectTrailingSlash`. Process-level
variables of the tests and tools (`VELA_STRICT`, `VELA_CI`, `VELA_PG`, `VELA_TLS_RSS_MB`...) are described in `tools/check.sh`.

`LoopStats` (per worker, for metrics and tests): `inFlight`, `peakInFlight`, `connections`, `rejected`, `cancelled`, `timedOut`,
`stalls`, `handlerErrors`, `fibersPoisoned`, `http2Connections`, `http2Streams`, `tlsHandshakes`, `tlsFailures`...
