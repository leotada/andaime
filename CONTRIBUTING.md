# Contributing to vela

The project's rules (language, `@safe`, no heavy Phobos in the core, one-line compile errors, the concurrency and response
contracts) are in [AGENTS.md](AGENTS.md); read it before changing `engine/`, `http/` or `web/`. [PLAN.md](PLAN.md) holds the
improvement plan and its decision log. Everything is written in English: code, comments, messages, docs and commits.

## Layout

| Package | Role | Depends on |
|---------|------|------------|
| `vela:http` (`http/`) | HTTP types, `Optional`, text types, zero-copy HTTP/1.1 parser and writer, chunked decoder, HTTP/2 session and HPACK, WebSocket frames and messages. No I/O. | — |
| `vela:web` (`web/`) | `App`, router, handler introspection, JSON, OpenAPI, middleware, cookies, streaming, WebSocket routes, `TestClient`. No sockets. | http |
| `vela:engine` (`engine/`) | epoll loop, fibers, buffers, `offload`, HTTP/HTTPS and WebSocket client, OpenSSL, zlib. No routes. | http |
| `vela-pg` (`drivers/pg/`) | PostgreSQL driver over async libpq. An independent package: the core never depends on it. | vela:engine |
| `vela` (`source/vela/`) | `import vela;`, `server.d` (the only glue between web and engine), static files | all |

## Toolchain

DMD 2.109.1+ or LDC 1.40.1+ (both minimums are tested in CI), DUB, Linux x86_64. A change is done when `tools/check.sh` passes
on **both** compilers.

## The test suite

```sh
tools/check.sh                       # everything, with DMD
DC=ldmd2 tools/check.sh              # with LDC
VELA_ONLY="memory" tools/check.sh    # only the sections whose name contains the text
VELA_STRICT=1 tools/check.sh         # a skipped section fails the run (CI does this)
```

`check.sh` runs sections: unittests, the web layer, documentation examples, OpenAPI validity, the parser, HTTP/2 session and
WebSocket layer with mutation fuzzing, the GC-free hot path, network tests (HTTP/1.1, HTTP/2, HTTPS, WebSockets),
interoperability (curl, python-h2, h2spec, python websockets, Caddy, Chromium), PostgreSQL, the HTTP client, the API example end to end, memory ceilings, compile-error tests, DUB
builds and the compile-time budget. A section whose tool is missing exits 77 and is listed as skipped in the summary.

### Optional tools

Without them the matching sections are skipped. A setup that runs every section locally:

| Tool | For | How |
|------|-----|-----|
| PostgreSQL | `vela-pg`, the API example | a local server (found automatically), or a container: `podman run -d --rm -e POSTGRES_HOST_AUTH_METHOD=trust -p 127.0.0.1:55432:5432 postgres:16` and `VELA_PG="host=127.0.0.1 port=55432 user=postgres dbname=postgres"` |
| python3 + `h2`, `openapi-spec-validator`, `websockets` (13+) | HTTP/2 and WebSocket interop, OpenAPI validity | `pip install h2 openapi-spec-validator 'websockets>=13'` (a venv is fine: put its `bin` first on `PATH`) |
| h2spec 2.6.0 | HTTP/2 conformance | the release binary; `H2SPEC=/path/to/h2spec` |
| Caddy 2 | h2c reverse-proxy test | the release binary; `CADDY=/path/to/caddy` |
| Playwright + Chromium | the real-browser test | `pip install playwright && playwright install chromium` |
| OpenSSL 3, curl with HTTP/2 | HTTPS and interop | system packages |

CI (`.github/workflows/check.yml`) pins h2spec and Caddy by checksum and runs the browser test and nightly fuzzing in their own
jobs.

### Other tools

```sh
tools/fuzz.sh 300 parse              # libFuzzer + ASan on the HTTP/1 parser (needs LDC); "h2": HTTP/2 session, "ws": WebSockets
tools/h2_interop.sh                  # HTTP/2 against curl, python-h2 and h2spec
tools/ws_interop.sh                  # WebSockets against python websockets (server and client, permessage-deflate)
tools/proxy_interop.sh               # behind Caddy over h2c
tools/bench.sh 10                    # requests per second of one worker, for before/after comparisons
```

### Numbers the suite enforces

- The hot path does not allocate on the GC (`tests/alloc/`).
- Peak RSS under 30 MB for 1,000 in-flight requests over HTTP/1.1 and HTTP/2, and for 1,000 open WebSockets; under 80 MB over
  HTTPS (OpenSSL 3.5).
- `examples/hello/source/app.d` type-checks in under 400 ms on DMD (fails above 440 ms; timing is noisy).
- Every invalid handler signature is a one-line `static assert` with a case in `tests/compile_fail/` (at most 2 error lines).

## Conventions

- Library messages start with `vela:` (`vela.db:`, `vela.http:` for the driver and client).
- New code is `@safe`; every `@trusted` has a one-line comment saying why it is sound.
- No `std.format`, `std.conv`, `std.json`, `std.regex`, `std.algorithm`, `std.range` in `http/`, `web/`, `engine/` (compile
  time). Tests and examples may use them.
- A test that cannot run prints `skip: <reason>` to stderr and exits 77.
- Documentation examples whose first line is `// check` are compiled by `tools/doc_examples.sh`: make them complete programs.
  User docs live in `docs/` (index: [docs/README.md](docs/README.md)); keep them in sync with behavior.
- In test clients, D's GC interrupts blocking `read`/`send` with `EINTR`: retry on it.
- One commit per item, each leaving `check.sh` green on both compilers.
