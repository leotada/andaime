# andaime documentation

New to andaime? Read [Getting started](getting-started.md) first, then the guides in order. The reference pages are for looking
things up.

## Guides

| Page | What it covers |
|------|----------------|
| [Getting started](getting-started.md) | Install, the first route, a CRUD with JSON, a first test |
| [Routing](routing.md) | Methods, path parameters, groups, controllers, 404/405, trailing slashes, the route table (`ANDAIME_ROUTES`) |
| [Reading the request](requests.md) | Path, query, JSON body, query/form models, file uploads, headers, cookies, `Optional`, partial updates (`PatchField`), any JSON value (`JsonValue`), client IP, your own types |
| [Validation and errors](validation.md) | Validation attributes, the 422 format and its error codes, your own validation response (`onValidationError`), other error statuses |
| [Responses](responses.md) | Return types, status codes, JSON, `Response`, headers, cookies |
| [Middleware and error handling](middleware.md) | Writing middleware, order, `Local!T`, access log, request id, CORS, `onError`, `mapError` |
| [Logging](logging.md) | `andaime.log`: levels, `text`/`kv`/`json` lines, the request id on every line, `ANDAIME_LOG_LEVEL` |
| [Streaming](streaming.md) | `Stream` and Server-Sent Events, backpressure, cancellation |
| [WebSockets](websocket.md) | `WebSocket` routes, `WsConn`, broadcasting, limits, compression, the `wsConnect` client, testing, proxies |
| [Static files and OpenAPI](static-files-and-openapi.md) | `serveStatic`, `/openapi.json` and Swagger UI, documenting statuses |
| [Concurrency](concurrency.md) | Workers, fibers, state between workers, waiting without blocking, `offload`, cancellation |
| [Database](database.md) | The PostgreSQL driver (`andaime-pg`) |
| [Jobs and cron](jobs-and-cron.md) | Background jobs (`andaime:jobs`), retries, uniqueness, cron, process roles, Postgres queue |
| [HTTP client](http-client.md) | Calling other APIs from a handler, reading their JSON (`fromJson`, `parseJson`) |
| [Cryptography](crypto.md) | `andaime:crypto`: bcrypt, SHA-256/HMAC/HKDF, AES-GCM, ES256 (JWT), ECDH, Web Push encryption |
| [Testing](testing.md) | `TestClient`: requests and responses in memory, JSON and multipart helpers, a cookie jar |
| [Memory safety](safety.md) | `@safe` handlers, strict mode, what you may keep from a request |

## Running in production

| Page | What it covers |
|------|----------------|
| [Deploying](deploy.md) | From `dub build` to a VPS: systemd, HTTPS with Let's Encrypt, logs, checks |
| [HTTPS](tls.md) | Certificates, reload without restarts, the redirect port, ACME challenges |
| [HTTP/2](http2.md) | h2 over TLS and h2c, proxies that speak h2c, limits, what is not implemented |
| [Configuration reference](configuration.md) | Every `ServerConfig` field and its default |

## Examples

- `examples/hello`: an in-memory CRUD with a controller, middleware and tests.
- `examples/api`: Postgres, an external API, Bearer authentication, CORS, static files, OpenAPI and `onError`.
