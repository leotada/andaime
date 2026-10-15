# AGENTS.md

Guidance for AI coding agents (and humans) working on this repository.
The code uses the provisional name **vela** (DUB package `vela`, `import vela;`); the repository is `dapi`.
`PLAN.md` holds the improvement plan with its decision log (owner decisions D1-D4, planner decisions P1-P9) and what was done.

## What this is

A micro web framework in D with FastAPI-style ergonomics: a handler's signature is its HTTP contract, and the
extraction/validation/dispatch code is generated at compile time (CTFE, `__traits`, shallow `static foreach`).
Targets: compile time under 400 ms for an example app on DMD, low RSS on cheap VPSs (15-30 MB under traffic),
one fiber per request on an epoll loop, readable one-line compile errors.

## Language and style rules

- **Write everything in English**: code, identifiers, comments, error messages, log lines, test names, docs, commit messages.
- **Use `@safe` wherever possible.** New code is `@safe` (and `nothrow`/`pure`/`@nogc` where it is natural, never forced).
  Escape hatches (`@trusted`) are small, named, and carry a one-line comment saying why they are sound. `@system` only where
  unavoidable (C bindings, raw pointers, fiber/context switching).
- Idiomatic D in handlers and middleware (slices, strings, delegates, DTOs). Do not add defensive `@nogc` to user-facing code.
  The runtime assumes a low-latency GC; the hot path is nevertheless GC-free and a test enforces it.
- Keep the core free of heavy Phobos: no `std.format`, `std.conv`, `std.json`, `std.regex`, `std.algorithm`, `std.range`
  in `http/`, `web/` and `engine/` (they cost compile time). Tests and examples may use them.
- Prefer shallow constructs (`static foreach`, `static if`) over deep recursive templates.
- Every invalid handler signature must produce a **one-line `static assert` message** that says exactly what to fix
  (see `handlerError` in `web/source/vela/web/handler_traits.d`). Add a case to `tests/compile_fail/` when you add a rule.
- Error messages from the library start with `vela:` (`vela.db:`, `vela.http:`, `vela.jobs:` for the drivers, the client and jobs).
- Use only one import of a name per module (a private selective import next to a `public import` of the same name made
  `is(T == X!U, U)` false on DMD 2.109).
- Never use `pkill -f` with a pattern that appears in your own command line.
- `real` is a reserved word in D.

## Safety model (`@safe`)

- Framework-internal delegate types (`RequestCallback`, `HandlerFactory`, `WorkerInit`, `HandlerFn`, `offload`'s work delegate) are `@safe`.
- **User-facing callbacks accept `@system`** (`Middleware`, `ErrorHandler`, `UserHandler`, `ValidationErrorHandler`, route
  handlers, a text type's methods): user code may call C libraries without ceremony, and `@safe` code converts to them implicitly.
  The framework invokes user code only through `callMiddleware`, `callUser` (one overload per handler type, `application.d`;
  a validation handler is reached from `dispatch` through the `@safe` `Context.onValidation` that `App.freeze` sets), `callBuild` (the app build function, `server.d`), `callStream`/`callEvents` (stream
  bodies, `stream.d`), `callWebSocket` (a WebSocket body, `web/.../websocket.d`), `textFromString`/`textToString` (a user's
  text type, `vela.http.texttype`) and the `@trusted` lambda in `dispatch`. Add no other call sites.
- `-version=VelaStrictSafe` (dub: `versions "VelaStrictSafe"`) makes `handlerError` reject `@system` handlers with a one-line
  message (`tests/compile_fail/system_handler.d` declares its flag with a `// FLAGS:` line). `tests/web/system_code.d` proves
  that `@system` handlers, middleware and error handlers work by default.
- Every module starts with `@safe:` except the raw-syscall ones: `engine/.../epoll.d` and `devserver.d` stay `@system`;
  `EventLoop.run` is `@system` and `vela.server.serve` is the single `@trusted` entry point into them. Their overrides of
  `@safe` interfaces (`stop`, `awaitFd`, `sleepMs`, the `ResponseSink` methods) are small `@trusted` bodies.
- FFI modules (`drivers/pg`, `engine/.../httpclient.d`, `wsclient.d`, `tls.d`, `tlsserver.d`, `zlib.d`, `random.d`, `libpq.d`,
  `crypto/.../libcrypto.d`, `ec.d`, `aead.d`, `hash.d`, `bcrypt.d`) expose `@trusted` facades; raw
  pointers never leave them (`tlsserver.d`'s per-connection functions take an `SSL*` and are `@system`; only `epoll.d` calls
  them). Tests that need raw OpenSSL (`tests/net/tls_net.d`, `tls_loadgen.d`) declare a `vela.engine.*` module name to reach the
  package-protected table. Anything that hands out a raw view (`PgResult.text`) is `@system`.
- **Memory model of request data**: every slice vela hands to user code points into GC memory (`NO_SCAN` blocks from
  `BufferPool` and `ByteBuffer`; never `NO_INTERIOR`, never freed or `realloc`'d by hand; `GC.malloc` is `extern (C)`, so a
  function-pointer cast must say so). A slice kept past the request is memory-safe -- it keeps its block alive -- but it may show
  bytes of a later request that reused the buffer. `Header!"X"` and `Cookie!"x"` hold copies. Never reintroduce `free`/`realloc`
  on a buffer user code can reach. Buffers are still pooled, so the hot path allocates nothing after warm-up (`tests/alloc`).
  A pooled worker must not pin a big buffer: `releaseWorker` clears `req` and the header table, `server.d` clears `ctx.request`.
- `__gshared` data is `@system`: read it through a small `@trusted` accessor and say why it is sound (usually "written once before
  the workers start"). The accessor returns `const` or `immutable` data, never a mutable `ref`; writes go through a separate
  `@system` setter that `main` calls before `serve` (see `examples/api`).
- A new `@trusted` needs a one-line comment saying why it is sound. When unsure, keep it `@system`.

## Layout

| Path | Role |
|------|------|
| `http/` (`vela:http`) | HTTP types, `Optional`, `PatchField`, text types, wire names (`@naming`, `@wireName`: `naming.d`, shared by JSON, OpenAPI and vela-pg), IP/CIDR, UTF-8, zero-copy HTTP/1.1 parser, chunked decoder, response head/sink, writer, byte buffer, HTTP/2 session (`h2.d`) and HPACK, WebSocket frames/handshake/`WsConn` (`websocket.d`), SHA-1 and base64, base64url (`base64url.d`). No I/O. |
| `web/` (`vela:web`) | `App`, `Group`, router, handler introspection, JSON and `JsonValue`, OpenAPI, CORS, cookies, streaming, WebSocket routes, models, middleware, `TestClient`, and the logger `vela.log` (`web/source/vela/log.d`: in `vela:web` so `jobs` and the root package use it; it writes to fd 2 and nothing else). No sockets. |
| `engine/` (`vela:engine`) | epoll loop, fibers (`sleep`/`awaitFd`), buffer pool, `offload`, `randomBytes` (getrandom, `random.d`), HTTP/HTTPS client (and `httpfake.d`, a scripted `HttpTransport` for tests), WebSocket client (`wsclient.d`), OpenSSL (dlopen, `tls.d`), zlib (dlopen, `zlib.d`), the server's TLS listener (`tlsserver.d`). No routes or DTOs. |
| `crypto/` (`vela:crypto`) | Cryptographic primitives over OpenSSL 3's libcrypto and libxcrypt (both dlopen, own `__gshared` tables): SHA-256, HMAC, HKDF, AES-128-GCM, P-256 ECDSA (ES256) and ECDH, Web Push encryption (RFC 8291), bcrypt. Depends on `vela:http` and `vela:engine` (`random.d`, `offload`). Nothing else depends on it. |
| `jobs/` (`vela:jobs`) | Background jobs: `@Job` / `perform`, in-memory and test queues, cron, `--role` and `--queues`. Depends on `vela:web` and `vela:engine`. The root package does not depend on it. |
| `drivers/pg/` (`vela-pg`) | PostgreSQL driver over async libpq (dlopen). **Independent package; the core must never depend on it.** |
| `drivers/pgjobs/` (`vela-pg-jobs`) | Postgres `JobStore` (`PgJobStore`): `SKIP LOCKED` claims, `LISTEN`/`NOTIFY`, a lease reaper, one cron slot across processes. Depends on `vela:jobs` and `vela-pg`. |
| `source/vela/` (`vela`) | `import vela;`, `server.d` (the only glue between web and engine), `staticfiles.d`. |
| `examples/hello`, `examples/api` | In-memory CRUD; a real API with Postgres, external API, CORS, static files, OpenAPI. |
| `tests/` | `web/` (no network; helper modules in `web/support/`), `jobs/` (no network), `h2/` (HTTP/2 session), `net/` (real sockets), `db/` (needs Postgres), `fuzz/`, `alloc/`, `compile_fail/`, `example/`. |
| `tools/` | `check.sh` (everything), `fuzz.sh`, `h2_interop.sh`, `stream_interop.sh`, `ws_interop.sh` (python `websockets`), `proxy_interop.sh` (behind Caddy over h2c), `crash_check.sh`, `openapi_validate.sh`, `doc_examples.sh`, `bench.sh`, and the helpers that start a throwaway Postgres / test upstream. |
| `docs/`, `README.md` | User-facing docs: `docs/README.md` is the index (guides: getting-started, routing, requests, validation, responses, middleware, streaming, websocket, static files/OpenAPI, concurrency, database, jobs and cron, http-client, testing, safety; reference: deploy, tls, http2, configuration). Keep them in sync with behavior; code blocks whose first line is `// check` are compiled by `tools/doc_examples.sh`. Contributor material goes in `CONTRIBUTING.md`, not the README. |
| `.github/workflows/check.yml` | CI: DMD and LDC at the minimum and latest versions, strict mode; browser test and nightly fuzzing in their own jobs. |

Dependency direction: `http` <- `web`, `http` <- `engine` <- `drivers/pg`. `jobs` depends on `web` and `engine`, not on `pg`.
`drivers/pgjobs` depends on `jobs` and `vela-pg`. `crypto` depends on `http` and `engine`; nothing in the core or `jobs`
imports it (`check.sh` greps for it). The root `vela` package does not depend on `jobs`. `web` does not depend on
`engine`. `source/vela/server.d` is the only module that knows both `web` and `engine`. Do not introduce a dependency from the
core to any driver.

## Commands and the definition of done

```sh
tools/check.sh                 # full verification (DMD); DC=ldmd2 for LDC
VELA_STRICT=1 tools/check.sh   # a skipped section fails the run (CI does this)
VELA_ONLY="memory" tools/check.sh   # only the sections whose name contains the text
tools/fuzz.sh [seconds] [parse|h2|ws|json]  # libFuzzer + ASan on the HTTP/1 parser, the HTTP/2 session, WebSockets or the JSON reader (needs LDC)
tools/ws_interop.sh            # WebSockets against python's `websockets` (server and client, permessage-deflate); also run by check.sh
tools/bench.sh [seconds]       # throughput (req/s) of one worker, with and without pipelining; for before/after, not a gate
tools/h2_interop.sh            # HTTP/2 against curl, python-h2 and h2spec (H2SPEC=/path); also run by check.sh
```

- A change is done when `tools/check.sh` passes on **both** DMD and LDC (minimum supported: DMD 2.109.1, LDC 1.40.1), with new
  tests, a `compile_fail` case for every new signature rule, the hot path still GC-free and the memory numbers within their limits.
- **Skips**: a test or helper that cannot run prints `skip: <reason>` to stderr and exits **77**; `check.sh` lists the skips in its
  summary. `dmd -run` turns every non-zero code into 1, so tests that can skip are built first and run afterwards.
- Timing checks are noisy: the compile budget fails above 440 ms (target 400), the HTTPS memory ceiling is 80 MB (OpenSSL 3.5).
- Parser changes: add corpus files and run `tools/fuzz.sh 300 parse`. JSON reader changes (`json.d`, `jsonvalue.d`): run
  `tools/fuzz.sh 300 json` (`JsonValue` recursion is bounded by `JsonLimits.maxDepth`; keep it so). HTTP/2 and WebSocket
  changes: see below.

## Concurrency model (read before touching `engine/` or `drivers/`)

- One worker per core (`SO_REUSEPORT`), each with its own epoll loop. **One fiber per request.**
- **One `App` per worker** (D1): `serve(build)` takes a build function; each worker calls it once, on its own thread (`WorkerInit`
  in `loop.d`; worker 0 first, alone). Everything the build function creates belongs to that worker, so no App state needs a lock.
  `serve` refuses a build function that returns the same App twice. Never hand an `App`, a controller or a connection to another worker.
- Waiting for I/O inside a handler must go through `awaitFd`/`sleep` (or a library built on them: the Postgres driver, the HTTP
  client). Any blocking call stalls the whole worker; the loop logs a warning past `stallWarnMs`.
- CPU-heavy or blocking-library work goes through `offload(...)` (bounded thread pool; `PoolSaturated` when the queue is full).
- Cancellation (client gone, deadline, a reader that stopped reading) is delivered as `RequestCancelled` (a `Throwable`) at the
  handler's next wait or write; `scope(exit)` and destructors run normally.
- Module-level variables in D are **thread-local**. Share across workers only with `__gshared`/`shared` and a reason, behind a lock
  that is never held across an I/O wait. `pgPool(...)` and `httpClient()` are per worker.
- **Per-request state that the code below a handler needs** (the logger's request id) lives with the request's fiber:
  `Worker` is a `LocalFiber` (`fiberio.d`) whose `fiberLocal` slot `server.d` sets to the request's `Context`. Never keep
  such state in a thread-local variable: requests interleave on one thread at every wait. Without fibers (`TestClient`,
  the devserver) `App.handle` sets `vela.log`'s per-thread source instead.
- **Errors inside handlers** (D4): an `Exception` becomes a 500 through the app (logged with a stack trace, 5 traces per second per
  App); an `Error` (RangeError, AssertError...) also gets a 500, a full trace in the log (5 per second per worker, the rest
  counted), and the fiber is retired (`LoopStats.fibersPoisoned`): after an `Error`, cleanup may not have run. A fiber stack
  overflow is a SIGSEGV that kills the process; `onCrash` in `epoll.d` prints which request was running first.

## Background jobs (read before touching `jobs/` or `drivers/pgjobs/`)

- `perform` is `@safe`. A missing `perform`, an `@system` `perform`, a payload `writeJson` cannot encode, or a bad `@Cron` is one
  line from `jobError`, asserted by `JobSet`. Cover a new rule with `tests/compile_fail/job_*.d` (`// FLAGS: -Ijobs/source`).
- I/O that waits (`sleep`, `awaitFd`, the Postgres driver, the HTTP client) runs on the fiber. CPU-heavy work and blocking C go
  through `@Offload` or `offload`.
- A Postgres claim is `UPDATE ... WHERE id IN (SELECT ... FOR UPDATE SKIP LOCKED)` and that transaction commits before `perform`.
  Do not hold the row lock across the work.
- Cron dedupe across processes is `INSERT ... ON CONFLICT` on `(job_name, scheduled_slot)` in `vela_cron_executions`
  (`claimCron` / `claimCronSlot`). The supervisor enqueues only when that insert wins. `PgJobStore.startServices`
  starts `LISTEN` and the reaper on worker 0; an empty claim waits for a notification or 5 seconds.
- Shutdown stops calling `claimBatch`. `release` returns an in-flight row to `retryable` without spending the attempt: a claimed
  row not yet run, `RequestCancelled` inside `perform`, and an `Error`. `--role=worker` and `--role=all` (`applyJobGrace`)
  raise `shutdownGraceMs` from the 10 second default to 30 seconds. A value the application already set is kept.
- The cron parser (`cronError`, `parseCron`) is `@safe pure nothrow @nogc`. Keep it that way.
- `InMemoryJobStore` is one thread. `runJobs` forces `workers = 1` by default. Several cores or processes use `PgJobStore`, one
  store per worker thread, and only worker 0 consumes. Queue concurrency is how many jobs that worker runs at once, not per core.
  One fiber per queue claims. `WorkerHooks.extra` runs on worker 0 before the loop polls: `spawn` from there, and do not call
  `sleep` or `awaitFd` in `extra` itself. A store failure is logged (`vela.jobs:`) and the fiber continues.

## The response contract (read before touching `engine/`, `server.d` or `web/.../stream.d`)

- The engine calls `RequestCallback(ref Request, ResponseSink)` (`vela.http.response`): `sink.start(ResponseHead)`, any number of
  `sink.write(bytes)`, `sink.end()`. The web layer never produces HTTP/1.1 text and the HTTP/2 session never parses it: both
  protocols encode from the structured head.
- `Worker` is the sink. Output goes to `w.output`; on HTTP/1.1 the loop sends it after the handler returns (the buffered case), or
  the fiber sends it itself once `streamHighWaterBytes` are buffered or on `flush` (waiting for `EPOLLOUT` in `waitWritable`,
  `writeTimeoutMs` at most; `awaitFd` is not used for the connection's own fd). Known `contentLength` -> `Content-Length`; unknown ->
  chunked (HTTP/1.1) or close-delimited (HTTP/1.0); HEAD, 204 and 304 discard writes. On HTTP/2 the stream is *committed* (HEADERS +
  the bytes so far) at the high-water mark or on `flush`; `H2Session.beginResponse/sendData/endResponse` carry the rest and
  `pendingBytes` suspends the handler. Before the commit a failure is a clean 500; after it only a cut-off is possible
  (`ResponseAborted`: connection closed without the last chunk / `RST_STREAM(INTERNAL_ERROR)`).
- `requestTimeoutMs` ends at `start`; then `writeTimeoutMs` bounds each blocked write and `streamTimeoutMs` (0 = none) the stream.
  A streaming handler keeps its fiber and counts toward `maxInFlight`.
- The sink copies: never hold the caller's slice past `write`. Never call `closeConn` from inside the fiber: mark
  `cancelled`/`failed` and let `finish`/`finishH2` act.
- Web layer: `Stream`/`EventStream` run inside `dispatch`; the head is committed lazily by `commit()` in `stream.d`, which runs the
  same `checkResponse` (owned headers, validation, `Date`) as `App.handle` and locks the headers. `server.d` and `TestClient` both
  finish with `sendResponse`.
- Request bodies: HTTP/1 chunked bodies are decoded in place by `ChunkedDecoder` (`tryParse`); the decoded body ends up right after
  the head and the next pipelined request right behind it, so `compact(c.total)` is unchanged.
- Pipelining (cleartext HTTP/1.1): when the next request is already in the buffer, `coalesce` appends the finished response to
  `Conn.pending` instead of sending it, so a batch of responses leaves in one send (16 KiB at most). `pendingQ` sends it at the end
  of the event batch at the latest. **Every write to the connection sends `pending` first**: `trySend`, `sendFully` (from the
  fiber), `sendRaw`; an error that closes the connection goes through `closeAfterSend`; an `Upgrade: h2c` behind held-back
  responses is served as HTTP/1.1. A new place that writes to an HTTP/1 connection must keep that order.
- The loop parses each head once: `parseHead` (in `tryParse`) fills the loop's `head`/`scratch`, and `parsedHead` hands it to
  `startRequest`, `tryUpgrade`, the `Expect` check and the redirect port, parsing again only if another connection's head or a
  grow came in between. Nothing else may write into `scratch`.
- `sink.upgrade(head, protocol)` instead of `start` answers 101 and hands the connection over (an `UpgradedConn`); on HTTP/2 it
  answers an extended CONNECT with `head` (2xx) and hands the stream over. It returns null where that is impossible
  (`BufferedSink`, the devserver, an HTTP/2 stream that is not an extended CONNECT), before anything was sent. See the
  WebSocket section.

## WebSockets (read before touching `http/.../websocket.d`, `web/.../websocket.d`, `wsclient.d` or `Phase.upgraded` in `epoll.d`)

- Layers: `vela.http.websocket` has the codec, the handshake and `WsConn` (the whole message layer: fragments, pings, close
  handshake, limits, ping/idle timing, deflate hooks) and does I/O only through `UpgradedConn` (`vela.http.response`). The engine
  implements `UpgradedConn` on a server connection (`WsPort` in `epoll.d`), `wsclient.d` on a client one, `TestClient` in memory.
  Protocol rules belong in `WsConn`, where the unittests, `tests/web/websocket.d` and the fuzzers reach them without sockets.
- The web layer never imports the engine: compression reaches it as `Context.newDeflate` (a `WsDeflateFactory`), set by
  `server.d` to `vela.engine.zlib`.
- The takeover (`sinkUpgrade`): pending pipelined answers go into `wsOut` before the 101; bytes after the request in `c.buf`
  become the first WebSocket input (`wsIn`); `c.buf` itself stays untouched until the connection closes, because the handler's
  `Request` (and its captured params) point into it. The connection never goes back to HTTP.
- Reads belong to the owner (the fiber that upgraded). Any fiber of the worker may write: `write` appends the whole frame to
  `wsOut` before it can wait, so frames never interleave. Writers wait for the drain like `waitH2Drain`; a dead connection gives the
  owner `RequestCancelled` and other fibers `WsClosed`. **Never resume a fiber from inside another fiber**: a wake-up decided in
  fiber context goes through `wsDefer` and runs at the end of the batch (`drainWsWakes`).
- A `WsPort` (and a `WsConn`) is per connection, never pooled: a `WsConn` kept by another fiber after its connection ended must
  find it closed, never reach a later connection on the same pooled `Conn`. Every `WsConn` method checks its state before I/O.
- When the owner returns, `finishUpgraded` sends what is left of `wsOut` (`writeTimeoutMs`) and closes with `lingerClose`;
  graceful stop wakes the readers (`fill` returns `stopping`, `WsConn` closes with 1001). `sweepUpgraded` drops a connection
  whose output is blocked longer than `writeTimeoutMs`.
- Over HTTP/2 (RFC 8441) a WebSocket is a stream. The session announces `SETTINGS_ENABLE_CONNECT_PROTOCOL`
  (`H2Config.enableConnectProtocol`, `ServerConfig.http2WebSockets`), hands an extended CONNECT out at its HEADERS as a GET
  with `Request.connectProtocol` (`H2Stream.tunnel`), and keeps its DATA for the engine (`tunnelInput`/`tunnelConsume`,
  `popInput`): the stream window is credited only as the owner consumes, so it bounds the buffer. `runWebSocket` answers 200
  without an accept key; only a WebSocket route may answer an extended CONNECT (`dispatch` refuses it with 400 elsewhere).
- The engine side is `H2Tunnel` in `epoll.d` (one per stream, never pooled, like `WsPort`): `upgradeStream` sends the 2xx with
  `beginResponse`; writes are `sendData` plus a wait in `t.writers` (woken from `wakeH2Writers`); readers and writers are
  woken with `wsDefer`; a peer RST breaks the tunnel (`tunnelBreak`: the reader sees 1006) instead of cancelling the owner.
  `finishTunnel` ends the stream with `endResponse` (END_STREAM after the queued DATA) or `cancelStream(CANCEL)`; the session
  then keeps it half-closed (local) until the peer's END_STREAM, resetting it after a second (`tick`). `closeH2` detaches
  every tunnel before it cancels the owners. Set `st.deadlineMs = 0` at the upgrade: WsConn's pings are the liveness check.
- A WebSocket change: cases in `tests/web/websocket.d` (TestClient, `c.http2 = true` for RFC 8441) or `tests/net/ws_net.d` /
  `tests/net/ws_h2_net.d` (sockets), `tools/ws_interop.sh`, `tools/fuzz.sh 300 ws` (and `h2` for the session's tunnels), and
  the hot path (`tests/alloc/ws_hot_path.d`, both transports) stays GC-free.
- A socket test client running in the server's process must retry `read`/`send` on `EINTR`: the server's GC stops every
  thread with signals.

## HTTP/2 (read before touching `http/.../h2.d` or the h2 part of `epoll.d`)

**Frozen (D3).** No new HTTP/2 or TLS features until the owner says so. Allowed: bug fixes, and the changes other plan items
require (response sink, memory model). The owner lifted it once, for WebSockets over HTTP/2 (RFC 8441, `PLAN.md` 10.7).
Everything below still applies to those.

- Protocol logic lives in `H2Session` (`vela.http.h2`), which does no I/O: the engine feeds it bytes (`receive`), runs what
  `popReady` hands out (one fiber per stream), cancels what `popReset` hands out, hands each response back with `respond` (or
  `beginResponse`/`sendData`/`endResponse` for a streamed body), and writes `pendingOutput`. Anything about frames, HPACK, stream
  states or flow control belongs in the session, where `tests/h2/session_test.d` and the fuzzers can reach it without sockets.
- A stream object the engine holds (`task` set) is never recycled by the session; the engine gives it back with `respond`,
  `endResponse`, `cancelStream` or `detach`. Stream and session objects are pooled: reset every field in `H2Stream.reset`/`H2Session.reset`.
- Never send RST_STREAM for a stream that was never opened (idle, or even-numbered): use a connection error.
- A connection that ends is closed with `lingerClose` (FIN, then discard input for up to a second): closing with unread input makes
  the kernel send RST and the peer can lose our last frames.
- An HTTP/2 change: a case in `tests/h2/session_test.d`, `tools/h2_interop.sh` (h2spec at 146/146 over TLS and 145/146 in cleartext:
  3.5/2 cannot pass on a mixed HTTP/1.1 port), and `tools/fuzz.sh 300 h2`. Inputs that once broke the session go in
  `tests/fuzz/h2_regressions/`.

## TLS (read before touching `tlsserver.d` or the TLS parts of `epoll.d`; also frozen, see above)

- Every read and write on a connection goes through `ioRead`/`ioSend` in `epoll.d`, never `read`/`send` on the fd: with TLS they
  go through OpenSSL with read(2)/send(2) semantics (EAGAIN for WANT_READ/WANT_WRITE).
- A short TLS read does not mean the socket is drained (one record at a time): keep reading until EAGAIN (edge-triggered epoll).
- OpenSSL writes with write(2): SIGPIPE must stay ignored (`loadOpenSsl` does it).
- Never call `SSL_shutdown` after a fatal TLS error (`Conn.tlsFatal`) or during the handshake.
- Each worker has its own `SSL_CTX` (no locks); ticket keys are shared so resumption works across workers.
- The redirect port (`tls.redirectPort`) is answered in `answerRedirectPort`, never by the app (no fibers, no handlers). ACME
  tokens are validated as base64url before touching the file system.
- Connection logs go through `logConnError` (rate-limited). Do not log clients that just close mid-handshake.
- The deploy config example in `docs/deploy.md` is compiled by `tools/doc_examples.sh`; its deploy hook must work with the reload
  logic. Re-check both when changing `TlsConfig` or the reload.

## Pitfalls

- dlopen function tables must live in a `struct` held by a `__gshared` instance (`pq`, `tls`, `z`), never in loose `extern (C)` variables
  (they become global symbols that the C library then calls itself).
- A user helper named `get`/`put`/`post`/`ws` hides vela's free functions; use `vela.get!(...)(app)`.
- DMD 2.109 segfaults on a call that relies on a default argument placed before a variadic parameter (`f(string a, S s = S.init,
  T[] rest...)`): use an overload instead (`TestClient.websocket`). It also crashes, instead of reporting it, on some name clashes
  between imported enums: when DMD dies with a segfault, try LDC for the real error message.
- A libFuzzer target has no D `main`: one that needs druntime (the monotonic clock, say) calls `rt_init` in
  `LLVMFuzzerInitialize` (`tests/fuzz/libfuzzer_ws.d`).
- Middleware applies to every route of its App/Group whatever the registration order; the app freezes when it starts serving
  (`App.freeze`) and registration then throws `RouteError`. Group prefixes cannot contain `{param}`.
- D's `args[i].ptr` of `main(string[] args)` is not NUL-terminated: use `std.conv` in tools, not `atoi`.
- A lambda mentioned inside `typeof` still makes older compilers allocate a closure for the variables it names: get return types
  from `typeof(fn)`, not from a probe lambda (`tests/alloc` caught it).

## Adding things

- **A new handler parameter kind**: add the wrapper in `web/.../params.d`, bind it in `handler_traits.d` (dispatch and `handlerError`),
  describe it in `openapi.d`, and add tests in `tests/web/` plus a `tests/compile_fail/` case for its misuse.
- **A new job rule**: extend `jobError` in `jobs/source/vela/jobs/job.d` with one `vela.jobs:` line, and add
  `tests/compile_fail/job_*.d` (`// FLAGS: -Ijobs/source`).
- **A new driver** (MySQL, Redis...): a new package under `drivers/`, depending only on `vela:engine`, using `awaitFd`/`offload`;
  load native libraries at run time (dlopen) so the framework still builds without them.
- **A new crypto primitive**: in `crypto/`, through `CryptoApi` in `libcrypto.d` (add the symbol to the table; OpenSSL 3
  non-deprecated API), a small `@trusted` body with a soundness comment, no raw pointer in the signature, an official
  test vector in `tests/crypto/` (which exits 77 when the library is missing), and a line in `docs/crypto.md`.
- **A new event-loop backend** (kqueue, io_uring): implement the `EventLoop` interface in `engine/source/vela/engine/loop.d`.
- **A new `Request` field**: every producer must set it -- the HTTP/1 parser (`parseRequestHead`), the HTTP/2 session
  (`finishRequest`), and for fields that do not come from the bytes (`peer`) the engine at both entry points -- because the
  fiber's `Request` is reused across protocols.
- **A new documented example**: start its code block with `// check` and make it a complete program; `tools/doc_examples.sh`
  compiles it.

## Out of scope for now

The rest of the performance work (M4: SIMD head search, GC tuning, `sendfile`; the benchmark, single parse and pipelined-response
coalescing are done, see `PLAN.md` Phase 8), kqueue (M5) and io_uring (M6), streamed (unbuffered)
request bodies, the WebSocket client over HTTP/2, Range requests, serving the app in cleartext next to TLS, IPv6 listeners, OCSP
stapling, response trailers (gRPC), streaming responses in the HTTP client. Do not start these unless asked.
