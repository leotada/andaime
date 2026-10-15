# vela improvement plan

Written on 2026-10-13, at commit `365cae1`, from a full review of the repository (code, tests, tools, docs,
`AGENTS.md`) and the owner's answers to the open design questions.

This document is meant to be handed off: whoever picks it up (a person or an agent) should not need the review
conversation. Every item says why it exists, what to change, how to test it, and when it is done.

---

## Implementation status

Phases 0 to 6 were implemented in one working session on top of commit `365cae1` (nothing is committed yet). Every item is
ticked below with a short "Done" note where reality differed from the text. Phase 7 and the open owner decisions were not
touched. Verified at the end: `VELA_STRICT=1 tools/check.sh` is green on DMD 2.109.1 and on LDC 1.40.1 (23 sections), with
Postgres (a `postgres:16` container), h2spec 2.6.0, curl and python-h2; `tools/fuzz.sh 300 h2` and `300 parse` ran clean.

**Not verified, so check these first:**
- `.github/workflows/check.yml` was never run on GitHub (it parses as YAML and runs the same `check.sh`). The first CI run may
  need small fixes (action versions, package names).
- ~~The real-browser test (Chromium via Playwright) was skipped on this machine~~ Ran on 2026-10-13 (Chromium 156, Playwright
  in a venv): all h2, redirect and HTTP/1.1 fallback pass. It had never passed as a section: its cleanup trap used a `local`
  that was gone when the trap ran (`btmp: unbound variable`); fixed in `tools/check.sh`.
- DMD "latest" and LDC "latest" (newer than 2.109/1.40) were not available here.

**Calls that loosened a number or changed a default (veto any of them):**
- The HTTPS memory ceiling went from 56 MB to **80 MB** (`VELA_TLS_RSS_MB`): OpenSSL 3.5 alone needs 55-65 MB at 1,000
  connections (the 56 MB figure was measured on OpenSSL 3.0), and moving the network buffers to the GC (decision D2) costs
  about 3 MB more there. HTTP/1.1 and h2 in cleartext stay under 30 MB.
- The compile-time guard fails above **440 ms** and warns between 400 and 440: on this laptop the same unchanged tree measured
  335-390 ms during one afternoon. The cost of the new features was +3% (13 ms) in a same-time comparison.
- `fiberStackBytes` default went from 128 KiB to **256 KiB** (512 KiB cost ~0.8 MB more RSS at 1,000 in-flight requests).
- `StaticConfig.maxFileBytes` default is now 1 GiB (files above 256 KiB are streamed, so it is a cap, not a memory limit).
- `App.logStackTraces` defaults to true (5 traces per second per App).

**Beyond the plan (found while implementing):**
- h2spec 7/1 failed about 1 run in 20: the server reset the connection after the peer's GOAWAY. Fixed with a lingering close.
- On DMD 2.109 / LDC 1.40 every handler with parameters allocated 16 bytes per request (a probe lambda inside `typeof` made
  the compiler build a GC closure); fixed, and the hot-path test now passes on the old compilers too.
- A fiber stack overflow now prints which request was running before the process dies (`tools/crash_check.sh`).
- After a burst of large uploads the GC could not give memory back (idle workers and cached buffers pinned its pools); the trim
  now retires idle workers and drops the cache first (200 uploads of 512 KiB: ~110 MB peak, ~41 MB three seconds after).

---

## Contents

- [How to use this plan](#how-to-use-this-plan)
- [Read first](#read-first)
- [Decision log](#decision-log)
- [Order and overview](#order-and-overview)
- [Phase 0 — Safety net](#phase-0--safety-net)
- [Phase 1 — Contained bug fixes](#phase-1--contained-bug-fixes)
- [Phase 2 — One App per worker](#phase-2--one-app-per-worker)
- [Phase 3 — Memory-safe request data](#phase-3--memory-safe-request-data)
- [Phase 4 — Streaming responses](#phase-4--streaming-responses)
- [Phase 5 — Missing basics](#phase-5--missing-basics)
- [Phase 6 — Docs and AGENTS.md](#phase-6--docs-and-agentsmd)
- [Phase 7 — Parked](#phase-7--parked-do-not-start-without-the-owner)
- [Phase 8 — Performance](#phase-8--performance-m4-first-items)
- [Phase 9 — Evidence for "HTTP/2 compatible"](#phase-9--evidence-for-http2-compatible)
- [Phase 10 — WebSockets](#phase-10--websockets)
- [Phase 11 — Features for real applications](#phase-11--features-for-real-applications)
- [Open owner decisions](#open-owner-decisions-not-blocking)
- [Appendix A — Evidence](#appendix-a--evidence-gathered-during-the-review)
- [Appendix B — Definition of done](#appendix-b--definition-of-done-every-item)

---

## How to use this plan

- Work through the phases in order. Each phase builds on settled foundations from the previous ones. Items inside a
  phase are independent unless they say **Depends on**.
- One item = one commit, or a short series of commits. Each commit leaves `tools/check.sh` green on **both** DMD and LDC.
  Small commits matter here: the project's history so far is 20k lines in 10 commits, which makes bisecting
  impossible.
- Line numbers refer to commit `365cae1` and will drift. Search for the quoted code instead of trusting the number.
- "Decide" inside an item means a small call left to the implementer. Anything bigger goes to the owner (see
  [Open owner decisions](#open-owner-decisions-not-blocking)). Record what you decided in the commit message.
- Tick the item's checkbox in this file in the same commit that finishes it.
- Size estimates are rough, for someone fluent in D who has read the code: **S** under half a day, **M** 1–3 days,
  **L** 3–10 days.

## Read first

1. **`AGENTS.md`** has the project rules. The ones that matter most here:
   - everything in English;
   - `@safe` everywhere possible, and every `@trusted` carries a one-line comment saying why it is sound;
   - every invalid handler signature gets a one-line `static assert` (via `handlerError`) plus a
     `tests/compile_fail/` case;
   - no heavy Phobos (`std.format`, `std.conv`, `std.json`, `std.regex`, `std.algorithm`, `std.range`) in `http/`,
     `web/` or `engine/`;
   - library messages start with `vela:`;
   - the core never depends on a driver;
   - a new `Request` field must be set by every producer: the HTTP/1 parser and the HTTP/2 session.
2. **Commands**: `tools/check.sh` (everything, DMD), `DC=ldmd2 tools/check.sh` (LDC), `tools/fuzz.sh [seconds] [parse|h2]`
   (libFuzzer + ASan, needs LDC), `tools/h2_interop.sh` (curl, python-h2, h2spec).
3. **Compilers**: the README says the project was tested with DMD 2.113 and LDC 1.43. The review machine had
   DMD 2.109.1 and LDC 1.40.1, and the full package does **not** build there (see 0.1). Until 0.1 is done, install
   matching compilers with <https://dlang.org/install.sh>.
4. **Invariants that every change must keep** (the tests enforce them):
   - the framework's hot path does not allocate on the GC (`tests/alloc/hot_path.d`, `tests/alloc/h2_hot_path.d`);
   - peak RSS stays under 30 MB for 1,000 in-flight requests over HTTP/1.1 and HTTP/2, and under 56 MB over HTTPS
     (memory section of `check.sh`);
   - the example's `app.d` type-checks in under 400 ms on DMD;
   - every compile error from a bad handler is at most 2 lines.
5. **HTTP/2 and TLS are frozen** (decision D3). Only bug fixes and the changes this plan requires are allowed there
   (items 3.2, 4.2 and 4.4). Any change in `http/.../h2.d`, `hpack.d`, `engine/.../tlsserver.d`, `tls.d`, or the
   HTTP/2 and TLS parts of `epoll.d` must still run:
   - `tools/h2_interop.sh`: h2spec stays at 146/146 over TLS and 145/146 in cleartext;
   - `tools/fuzz.sh 300 h2`;
   - a new case in `tests/h2/session_test.d`.
6. **The user-code call-site rule**: the framework calls user code only through `callMiddleware`, `callUser` and the
   `@trusted` lambda in `dispatch`. Phases 2 and 4 add exactly two new call sites (`callBuild`, `callStream`).
   Update the list in `AGENTS.md` when you add them, and add no others.

## Decision log

### Owner decisions

| # | Topic | Decision | Consequence for this plan |
|---|-------|----------|---------------------------|
| D1 | Threading model | **One App per worker.** `serve` takes a build function; each worker calls it once on its own thread. | Phase 2. The rule for users: everything created by the build function belongs to one worker. One process, so the GC is still shared (see the measurement in Phase 2). |
| D2 | Memory safety of zero-copy slices | **Copy `Header!"X"` values, and move network buffers to the GC.** | Phase 3. No `scope`, no preview flag, no API change for users. Kept raw slices are memory-safe but may show bytes from a later request. |
| D3 | HTTP/2 and TLS scope | **Frozen.** Keep them, keep their tests green, fix bugs only, and touch them only where streaming (Phase 4) or memory safety (Phase 3) needs it. | No new HTTP/2 or TLS features until Phases 0–5 are done. |
| D4 | `Error` inside a handler | **Answer 500, log the full stack trace, retire the fiber.** The server keeps serving. | Item 1.9. |

### Planner decisions (reversible; the owner can veto any of them)

| # | Decision | Why |
|---|----------|-----|
| P1 | Group middleware applies to every route of the group, whatever the registration order. The app is frozen when it starts serving. | Today `App.use` and `Group.use` follow two different ordering rules (item 1.7). Order-independence is what FastAPI users expect. |
| P2 | `serve(buildFn)` replaces `app.serve(...)`. The `App` overloads are removed, not deprecated. | Keeping them keeps the shared-App footgun. It is a prototype, so breaking changes are fine. |
| P3 | `Optional!T` moves to `vela:http`, and `Maybe!T` is removed from `vela-pg` with no deprecation period. | One concept, one type. `vela-pg` already depends on `vela:http` through `vela:engine`. |
| P4 | Validation errors follow a subset of Pydantic v2: `type`, `loc` (strings and integers), `msg`. No `input` field. | Matches what FastAPI clients parse. Leaving out `input` avoids echoing user data back. |
| P5 | An invalid response header turns the response into a 500 plus a log line. CR/LF are never stripped silently. Hop-by-hop headers are dropped, and `Content-Length` is always computed by vela. | Silent stripping hides bugs. A 500 is loud and safe. |
| P6 | Streaming API: handlers return `Stream` or `EventStream`. The stream body runs inside the middleware chain. The head is committed lazily (on the first write). After the commit, errors abort the response. | Middleware sees the real duration and outcome. An exception before the first write still gets a normal error response. |
| P7 | OpenAPI status codes come from `@status(201)`; error responses from `@responds(404, "...")`. | FastAPI's `status_code=` and `responses=`, expressed as D attributes. |
| P8 | A test that cannot run exits with code 77 ("skipped"). `check.sh` reports skips at the end; `VELA_STRICT=1` (used by CI) makes a skip fail the run. | Today a green run may have skipped Postgres, TLS, the browser test and h2spec without anyone noticing. |
| P9 | Try to support the distro compilers (DMD 2.109, LDC 1.40) if a few small fixes are enough. Otherwise require 2.113 / 1.43. | Contributors on openSUSE, Debian and others get those versions from their package manager. |

## Order and overview

| Phase | What | Size | Depends on |
|-------|------|------|------------|
| 0 | Safety net: compiler requirements, skip accounting, DUB builds, honest compile numbers, CI | M | — |
| 1 | Contained bug fixes (11 items) | L in total, each S–M | 0 |
| 2 | One App per worker (D1) | M | 1.7 |
| 3 | Memory-safe request data (D2) | M | 0 (memory tests running in CI) |
| 4 | Streaming responses | L | 1.1, 3 |
| 5 | Missing basics: client IP, chunked uploads, list queries, custom types, maps, query and form models, cookies | L in total | 1.1, 1.4; 5.6 before 5.7 |
| 6 | Docs and `AGENTS.md` restructure | M | each phase updates its own docs; Phase 6 is the final reorganization |
| 7 | Parked; needs the owner | — | — |

**Why this order.**
- The safety net comes first, so every later change is checked the same way locally and in CI.
- Phase 1 removes real bugs cheaply. It also settles the response-header API (validation, multiple values) that
  streaming builds on.
- Phase 2 changes the public `serve` call before the docs are rewritten around it.
- Phase 3 settles who owns buffers and whether they live on the GC. Phase 4's response sink must know that before it
  decides how output buffers are handed between the web layer, the engine and the HTTP/2 session.
- Phase 4 is the largest architectural change and benefits from everything before it.
- Phase 5 touches the same engine paths (`startRequest`, the parser), and is simpler once the response contract is
  final.

---

## Phase 0 — Safety net

### [x] 0.1 Declare and check the supported compilers — S

> **Done.** Minimum is DMD 2.109.1 / LDC 1.40.1 (P9 succeeded with 3 small fixes: `isDirMode`/`isRegMode` shims,
> `byValue` loops in `httpclient.d`, and a `dispatch` fix). The `dispatch` fix matters beyond compatibility: the
> `is(typeof(() @trusted { ... }()) == void)` probe made older compilers allocate a GC closure for `args` on every
> request with parameters, which `tests/alloc/hot_path.d` caught. `toolchainRequirements` is in all five `dub.sdl`
> files (DUB does check sub-packages). Also found: `-verrors=simple` does not exist on 2.109 (probed in `check.sh`).

**Why.** `dub.sdl` states no minimum compiler. On DMD 2.109.1 and LDC 1.40.1 the build fails with:

- `source/vela/staticfiles.d:103,113`: ``@safe function ... cannot call @system function `S_ISDIR` `` (and `S_ISREG`).
  Older druntime marks them `@system`.
- `engine/source/vela/engine/httpclient.d:297,305`: `` `_aaApply2` is not `nothrow` `` inside the `nothrow` functions
  `closeIdle` and `idleCount`, which iterate an associative array.

**Change.**
1. Try the old compilers (P9):
   - `S_ISDIR`/`S_ISREG`: add `private bool isDirMode(uint m) @trusted pure nothrow @nogc => S_ISDIR(m);` and an
     `isRegMode` twin, with the comment "sound: a pure bit test on an integer".
   - The two `nothrow` functions: wrap the AA loop in `try { ... } catch (Exception) {}`, or drop `nothrow` if no
     caller needs it.
   - Then run `tools/check.sh` on DMD 2.109 and LDC 1.40. If it passes after **at most ~5 small fixes of this kind**,
     the old versions become the minimum. If not, revert the shims and require 2.113 / 1.43.
2. Add to `dub.sdl` and `drivers/pg/dub.sdl` (it is an independent package):
   `toolchainRequirements dmd=">=<min>" ldc=">=<min>" gdc="no"`. Check whether DUB applies the root package's
   requirements to sub-packages; if it does not, add the line to `http/`, `web/` and `engine/` too.
3. README "Requirements": state the minimum and the latest tested versions.

**Done when.** `dub build` on a too-old compiler prints DUB's toolchain message instead of a wall of errors, and
`check.sh` is green on both the minimum and the latest versions.

### [x] 0.2 Count and report skipped tests — S

> **Done.** Beyond the plan: `VELA_ONLY="<text>"` runs only matching sections, `VELA_ALLOW_SKIP="<words>"` lets
> chosen skips pass in strict mode, and tests that can skip are built then run (`dmd -run` turns exit 77 into 1).
> `ldconfig` is in `/sbin`, outside the normal user's `PATH` on openSUSE, which had silently skipped the HTTPS memory
> test. Once it ran, the 56 MB HTTPS ceiling failed with OpenSSL 3.5 (55–65 MB; ~44 MB was measured on 3.0), so the
> default is now 72 MB (`VELA_TLS_RSS_MB`). **Owner: veto this if you prefer to keep 56 MB.**
> Found while testing: h2spec 7/1 failed about 1 run in 20 (RST instead of a clean close after the peer's GOAWAY);
> fixed with a lingering close in `epoll.d` (`lingerClose`), 0 failures in 80 runs afterwards.

**Why.** Many checks skip themselves with only a warning:
- `tools/with_postgres.sh`, `tools/with_upstream.sh`, `tools/api_e2e.sh` (which skips with **exit 0**);
- `tools/h2_interop.sh` (curl, python-h2, h2spec, openssl);
- the browser test and the HTTPS memory test in `check.sh`;
- `tests/db/pg_net.d` ("exit 0 with a warning").

So a green run may have tested much less than it seems. Also, `with_postgres.sh` only looks for Postgres under
`/usr/lib/postgresql/*/bin` (the Debian layout), so on openSUSE, Fedora or Arch it always skips.

**Change.**
1. Convention (P8): a test or helper that cannot run prints `skip: <reason>` to stderr and exits **77**. Apply it to
   every place listed above. Find any others with `grep -rn -i "skip\|warning" tools tests`.
2. `check.sh`: run each section through a `section "<name>" <command...>` helper that records ok, failed or skipped
   from the exit code. At the end, print a summary like `passed 23, failed 0, skipped 3: postgres, h2spec, browser`.
   Exit non-zero on any failure. With `VELA_STRICT=1`, a skip also fails the run.
3. `with_postgres.sh`: also find `initdb` through `pg_config --bindir` and `PATH`.

**Done when.** Running without Postgres lists `postgres` among the skips in the summary, and `VELA_STRICT=1` turns that
into a failure.

### [x] 0.3 Build through DUB — S

**Why.** `check.sh` compiles almost everything with `$DC -i -run`. The DUB packaging is barely exercised: sub-package
dependencies, `vela:web` not depending on `vela:engine`, the `vela-pg` path dependency. Only `api_e2e` builds through
DUB, and it skips without Postgres.

**Change.** Add a `dub builds` section to `check.sh`:
- `dub build --compiler=$DC` at the root;
- `dub build :http`, `dub build :web`, `dub build :engine` (a sub-package build fails if `web` imports `engine`, which
  proves the layering);
- `cd drivers/pg && dub build`;
- `cd examples/hello && dub build`, `cd examples/api && dub build`.

Also add a grep guard: `! grep -rn "import vela\.db" http web engine source` (the core must never import a driver).

**Done when.** The section passes on both compilers, and breaking the layering on purpose fails it.

### [x] 0.4 Honest compile-time numbers — S

> **Done.** Measured: type-check 335–430 ms (noisy; the budget step re-measures up to 3 rounds), edit-and-rebuild
> about 0.8–1.0 s (debug `dub build`).

**Why.** The budget step times `$DC -o- -c examples/hello/source/app.d`: no code generation, no linking. That is the
right guard for template cost, which is what the 400 ms target protects. But the README says "the example's `app.d`
compiles in ~250 ms", which readers take to mean the build time.

**Change.**
- Keep the 400 ms budget, but name it what it is in `check.sh` and the README: "type-checks in".
- Add a reported number that is not enforced yet: the edit-and-rebuild time. Do one warm `dub build` in
  `examples/hello`, then `touch source/app.d` and time a second `dub build`. Print it for DMD and LDC.
- Put both numbers in the README, each with what it measures. The owner decides later whether to enforce a budget on
  the rebuild time.

**Done when.** The README states both numbers correctly, and `check.sh` prints both.

### [x] 0.5 Continuous integration — M

> **Written but never run on GitHub** (no access from the implementation environment): the workflow's YAML parses
> and the `check.sh` it invokes passes locally. Watch the first run. The Postgres service uses
> `POSTGRES_HOST_AUTH_METHOD: trust` (with SCRAM, libpq's synchronous PBKDF2 stalls the single-threaded worker and
> `tests/db/pg_net.d` fails). h2spec 2.6.0 is pinned by SHA-256. Verify the `setup-dlang` major version (`@v2`).

**Why.** The repository (`github.com/leotada/dapi`) has no CI. Given how many optional dependencies the tests have,
a local green run proves little.

**Change.** Add `.github/workflows/check.yml`:
- Matrix: DMD and LDC, each at the minimum and latest versions from 0.1, installed with
  `dlang-community/setup-dlang` (check its current major version).
- Postgres: a `postgres:16` service with a health check. Export
  `VELA_PG="host=localhost port=5432 user=postgres password=postgres dbname=postgres"`; `with_postgres.sh` already
  uses `VELA_PG` when it is set.
- Packages: `libpq5`, `libssl3`, `python3`, `pip install h2`. curl on Ubuntu runners already supports HTTP/2. Download
  h2spec at a pinned version and verify its checksum.
- Run `VELA_STRICT=1 tools/check.sh` with `DC` from the matrix.
- Shared runners make timings noisy. With `VELA_CI=1`, the compile-time budget is printed but does not fail the run.
  Keep the memory assertions, since RSS does not depend on timing; if they turn out flaky, record it in this plan.
- A separate job, weekly or manual, for the Chromium test (`pip install playwright && playwright install --with-deps chromium`).
- A nightly job on LDC: `tools/fuzz.sh 600 parse` and `tools/fuzz.sh 600 h2`.

**Done when.** A pull request shows a green check, and a deliberately broken test turns it red.

---

## Phase 1 — Contained bug fixes

### [x] 1.1 Response headers: validation, multiple values, limits — M

> **Done.** Notes: capacity is 32 plus one reserved slot for `Date`, which the server now adds with `ensureHeader` (a
> user-set `Date` wins). Hop-by-hop headers and `Content-Length` are removed in `App.finishResponse`, so both protocols
> see the same result. `TestResponse.headers` (the field) was renamed `headerList` so that `headers(name)` could exist.

**Why.**
- **Response splitting (verified, see Appendix A).** `Response.redirect(to)` with `?to=/x%0d%0aSet-Cookie:%20pwned=1`
  produced the header value `"/x\r\nSet-Cookie: pwned=1"`. `writeResponseHead` (`http/source/vela/http/writer.d`, the
  `foreach (ref h; extra)` loop) writes names and values verbatim. The HTTP/2 path re-parses that text
  (`h2.d`, `queueResponse`), so the injected line would become a real header there too.
- **Two `Set-Cookie` headers are impossible (found while planning).** `ResponseState.setHeader`
  (`web/.../context.d`) replaces any header with the same name, and `writeResult` copies `Response.headers` through
  `setHeader`, so only the last cookie survives.
- **The header cap is an `assert`.** More than 16 response headers is an `assert`, which disappears in `-release` builds
  and leaves an out-of-bounds `RangeError` and a confusing 500.

**Change.**
1. `vela.http.types`:
   - `bool isValidHeaderName(scope const(char)[])`: non-empty, token characters only. Reuse the parser's `isTchar`
     (make it package-visible).
   - `bool isValidHeaderValue(scope const(char)[])`: only HTAB, 0x20–0x7E and 0x80–0xFF. This rejects CR, LF, NUL and
     every other control character (RFC 9110 field values).
2. `ResponseState`:
   - `setHeader(name, value)`: replaces the first header with that name and removes any other with the same name.
   - New `addHeader(name, value)`: appends, for `Set-Cookie`, `Link` and similar.
   - Raise the capacity to 32. On overflow, set a `headerOverflow` flag instead of asserting, so the method stays
     `nothrow @nogc`.
   - `writeResult` for `Response` uses `addHeader` for each entry, so duplicates survive.
3. `Context.addVary(token)`: merges tokens into a single `Vary` header (`Origin, Accept-Encoding`) without
   duplicates, building the value in `ctx.scratch`. Used by 1.6.
4. One validation point in the web layer, at the end of `App.handle` after the middleware has unwound. Both
   `server.d` and `TestClient` go through it, so tests see the same behavior. `checkResponse(ctx)` validates the
   `contentType` value, every header name and value, and the overflow flag. On a violation:
   - log `vela: response to GET /path has an invalid header 'Location' (CR, LF, NUL or a control character); answering 500`
     with the header **name only**, never the value (avoids log injection);
   - clear the headers and render the standard 500.
5. Headers vela owns (P5): when serializing for either protocol, drop user-set `Connection`, `Keep-Alive`,
   `Transfer-Encoding`, `Upgrade`, `Proxy-Connection` and `TE`, and ignore a user-set `Content-Length`. `Date` keeps
   being set by vela. Document all of this in the `ResponseState` doc comment.
6. Leave the HTTP/2 transcoder alone in this item. Validation upstream guarantees well-formed lines, and item 4.2
   removes the transcoder.

**Tests.**
- New `tests/web/headers.d`:
  - CR/LF in `Location` → 500 and the log line, with no value in the log;
  - NUL in a value, and an invalid name (`"Bad Name"`) → 500;
  - two `Set-Cookie` headers preserved (add `TestResponse.headers(name)`, returning every value);
  - `setHeader` replaces; `addVary` merges;
  - 33 headers → 500 with a clear log line.
- `tests/net/epoll_net.d`: raw bytes show hop-by-hop headers dropped and `Content-Length` correct.
- `tests/net/h2_net.d`: two `Set-Cookie` arrive as two fields.

**Done when.** The probe from Appendix A returns 500, and the tests above pass.

### [x] 1.2 Status reason phrases — S

**Why (found while planning).** `statusText` (`http/.../types.d`) has no entries for 502 or 504, yet the engine sends
504 on deadlines, so the wire shows `HTTP/1.1 504 Unknown`.

**Change.** Add at least 206, 303, 410, 411, 412, 416, 426, 428, 451, 502 and 504. Add unit-test cases for 502 and 504.

### [x] 1.3 One `Optional` type — S/M

> **Done.** `Optional` lives in `vela.http.optional`; `Maybe` is gone. Gotcha: a module that imports the same selective name twice (once private, once `public import`) makes `is(T == Optional!U, U)` evaluate false on DMD 2.109; keep a single import.

**Why (verified).** `vela-pg` has `Maybe!T` (fields `value` and `has`) and the web layer has `Optional!T`. A database
row with a `Maybe!string` field serializes as `{"email":{"value":"a@b.c","has":true}}`, with no error. The README's
database example (`README.md:88`) uses `Maybe`.

**Change (P3).**
1. Create `http/source/vela/http/optional.d` containing `Optional(T)` moved unchanged from `web/.../params.d`
   (`has`, `get`, `getOr`, the constructor). Add `static Optional none()` for parity with `Maybe`.
2. `vela.web.params` does `public import vela.http.optional : Optional;`, so user imports keep working. `isOptional`
   stays in the web layer.
3. `vela-pg`:
   - `parseCell`: NULL becomes `Optional.init`, anything else `Optional(value)`;
   - `Encoded`: an empty `Optional` is sent as SQL NULL;
   - error messages say "use Optional!X";
   - remove `Maybe`;
   - `vela.db` does `public import vela.http.optional : Optional;`.
4. Update `README.md:88`, the driver's doc comments, `tests/db/pg_net.d` and `examples/api`.

**Tests.** `pg_net.d`: select a NULL and a non-NULL value into a struct with `Optional!string`, return it from a
handler, and check `{"email":null}` and `{"email":"a@b.c"}`.

### [x] 1.4 Validation errors in FastAPI's format — M

> **Done.** Shared number helpers are in `web/.../numtext.d` (`ctNum`, `itoa`, `numText`; `openapi.d` uses them). A JSON syntax error now replaces the type errors collected before it with a single `json_invalid`. `typeHint` was replaced by `parseErrorType`/`parseErrorMsg` in `convert.d`.

**Why (verified, see Appendix A).**
- `loc` is `["body","items.code"]`; FastAPI gives `["body","items",1,"code"]`. Array indexes are lost: the array branch
  of `readJson` (`json.d`, around `v ~= e;`) never pushes an index, and `FieldPath` (`dto.d`) joins keys with dots.
- `@minLength(3)` accepts `"çã"` (2 characters, 4 bytes). `validateField` (`dto.d:130`) uses `.length`, which counts
  UTF-8 bytes, while JSON Schema's `minLength` (which the OpenAPI output claims) counts characters.
- There is no machine-readable error type, and some messages expose D type names: `"expected an integer (int)"`,
  `"value outside enum Order"`.
- `"outside the allowed range"` does not say which range.
- Errors beyond 16 are dropped silently: `FieldErrors.dropped` is counted but never reported.
- Invalid UTF-8 in a JSON string, or in a percent-decoded `string` parameter, is accepted into a D `string`, which is
  supposed to always be valid UTF-8.

**Change.**
1. Data model (`web/.../dto.d`):
   ```d
   struct FieldError
   {
       string location;  // "path" | "query" | "header" | "body"
       string locJson;   // rest of loc as JSON array elements, already rendered: `"items",1,"code"` ("" = none)
       string type;      // machine-readable code, see the table
       string message;
   }
   ```
   `FieldPath` becomes a fixed stack of up to 32 segments, each a key or an index, with `pushKey`, `pushIndex`, `pop`
   and `render()`. Deeper paths are truncated with a final `"..."` segment. Rendering happens only when an error is
   added, since the error path may allocate.
2. `readJson`: push the element index for arrays (structs already push the key).
3. Output format: `{"detail":[{"type":"missing","loc":["body","items",1,"code"],"msg":"Field required"}]}`.
   When `dropped > 0`, append `{"type":"too_many_errors","loc":[],"msg":"N more errors not shown"}`.
4. Error types (P4: Pydantic v2 names where one exists):

   | Situation | `type` | `msg` |
   |-----------|--------|-------|
   | missing required field, query parameter, header | `missing` | `Field required` |
   | missing JSON body | `missing` | `JSON body required` |
   | bad integer, or out of range for the D type | `int_parsing` | `expected an integer between MIN and MAX` |
   | bad float | `float_parsing` | `expected a number` |
   | bad bool | `bool_parsing` | `expected true or false` (the query also accepts 1/0; say so in the docs) |
   | enum value | `enum` | `expected one of: asc, desc` |
   | JSON value of the wrong type | `string_type` / `list_type` / `model_type` | `expected a string` / `expected an array` / `expected an object` |
   | `@minLength` / `@maxLength` on a string | `string_too_short` / `string_too_long` | `expected at least N characters` / `at most N characters` |
   | `@minLength` / `@maxLength` on an array | `too_short` / `too_long` | `expected at least N items` / `at most N items` |
   | `@inRange` below / above | `greater_than_equal` / `less_than_equal` | `must be >= MIN` / `must be <= MAX` |
   | JSON syntax error, extra content after the value | `json_invalid` | `invalid JSON at byte N` (use `JsonReader.errorPos`) |
   | invalid UTF-8 | `string_unicode` | `invalid UTF-8` |
   | invalid `%` encoding | `percent_encoding` (vela-specific; document it) | `invalid percent-encoding` |

5. UTF-8: add `bool validUtf8(scope const(char)[])` and `size_t codePoints(scope const(char)[])` to `vela.http`
   (written by hand, no `std.utf`). Validate in `decodeJsonString`, and in `parseScalarText` for `string` and for
   `const(char)[]`. String `@minLength`/`@maxLength` count code points; array lengths count elements.
6. Build messages at compile time where possible. Move `num`/`itoa` from `openapi.d` and `ctNum` from `dto.d` into one
   small shared helper.
7. OpenAPI `HTTPValidationError` component: `loc` items become `{"anyOf":[{"type":"string"},{"type":"integer"}]}`, and
   add a required `type` property.
8. Update every expected 422 body: the `examples/hello` unittest, `tests/web/*.d`, `tests/example/api_e2e.py`, and the
   examples in `docs/quickstart.md`.

**Tests.**
- Unit tests in `json.d`/`dto.d` for every row of the table.
- Nested paths (`items[1].tags[0]`) and depth truncation.
- 17 or more errors → a `too_many_errors` entry.
- `"çã"` with `@minLength(3)` → `string_too_short`.
- A raw `0xFF` byte in a JSON string, and `%FF` in a query `string` → `string_unicode`.
- The allocation test still reports 0 bytes on the success path.

### [x] 1.5 English everywhere — S

**Why.** Portuguese leftovers, some of them sent to API clients:
- `web/.../json.d:426,451,469`: `"esperado string"`, `"esperado array"`, `"esperado objeto"` (replaced by 1.4 anyway);
- `web/.../openapi.d:8`: `/// Detalhes:`;
- `tests/web/features.d:15,138`: `"proibido"`;
- `examples/hello/source/app.d:201`: `limit=muitos`.

**Change.** Translate them: `Details:`, `forbidden`, `many`. Run
`grep -rnP '[^\x00-\x7F]' http web engine source drivers --include=*.d` to review the remaining non-ASCII text; the
`µs` in the hello example and the `é` in JSON tests are intentional.

### [x] 1.6 CORS: `Vary` on every response — S

**Depends on** 1.1 (`addVary`).

**Why.** `web/.../cors.d` adds `Vary: Origin` only when it echoes an allowed origin. With a specific origin list,
responses to requests with no `Origin`, or a disallowed one, carry no `Vary`. A shared cache (CDN) can then store the
variant without CORS headers and serve it to an allowed origin, which breaks CORS. Preflight responses that echo
`Access-Control-Request-Headers` also vary on it.

**Change.**
- Unless the origin list is exactly `["*"]` with `credentials` off, call `ctx.addVary("Origin")` on every response that
  passes through the middleware: no `Origin`, a disallowed one, or an allowed one.
- Preflight responses: also `addVary("Access-Control-Request-Method")`, plus `"Access-Control-Request-Headers"` when
  echoing them. This applies even with `["*"]`.

**Tests.** The CORS cases in `tests/web/features.d`: no `Origin`, a disallowed origin, an allowed one, a preflight with
and without requested headers, and the `["*"]` case.

### [x] 1.7 Middleware order, and freezing the app — M

> **Done.** `RouteError` is now exported from `vela.web`. `Group` keeps a `parent`; chains are built in `App.freeze`. `serve` will call `freeze` per worker in Phase 2; until then `handle` freezes on the first request.

**Why.** Two different rules for the same verb:
- `App.use` takes effect for every request whenever it is called; the list is read at request time (`runFrom`,
  `application.d:267`).
- `Group.use` applies only to routes registered **after** it: the list is copied in `Group.register`
  (`application.d:97–106`).
- A subgroup snapshots its parent's list when it is created (`mws.dup` in `Group.group`).

A misordered call silently does something different in each case.

**Change (P1).**
- New rule:
  - a middleware applies to every route of its App or Group, no matter when the route is registered;
  - execution order is the order of the `use` calls, outermost first;
  - App middleware runs before routing, as today (CORS preflights and 404/405 need that);
  - Group middleware runs after routing, for matched routes of the group and its subgroups, parent's first.
- `Group` keeps a `parent` reference and its own list; nothing is copied. `register` records the route with its
  group.
- New `App.freeze()` (package-visible):
  - builds each route's `Chain` from its ancestors' middleware, root first, then its own;
  - builds the OpenAPI document eagerly, which removes the lazy `cached` write in `serveOpenApi`
    (`application.d:184–191`, a cross-thread race today);
  - sets `frozen`.

  Phase 2's `serve` calls it in each worker. `App.handle` calls it once if the app is not frozen yet, which covers
  `TestClient`.
- After the freeze, `use`, `register`, `group`, `mount`, `serveStatic`, `serveOpenApi`, `onError` and `onNotFound`
  throw `RouteError("vela: the app is already serving; register routes and middleware before serve (in the build function)")`.
- `serveOpenApi` now documents every route, including those registered after the call. Fix its comment
  (`application.d:179`).
- Update `AGENTS.md` ("Group middleware only applies to routes registered after `use`") and the README pitfalls.

**Tests** (`tests/web/features.d`):
- a middleware registered after the routes applies, both on the App and on a Group;
- a subgroup created before the parent's `use` still runs the parent's middleware;
- the execution order is correct;
- `use` after the first request throws with that message;
- OpenAPI includes routes registered after `serveOpenApi`.

### [x] 1.8 OpenAPI correctness — M

> **Done.** Type identity uses `T.mangleof` (unique), because `__traits(fullyQualifiedName, Page!(a.User))` does not include the argument's module. `@status`/`@responds` live in `params.d`, `@schemaName` in `dto.d`. A user struct named `HTTPError` or `HTTPValidationError` gets another name. The generated document validates with `openapi-spec-validator` (`tools/openapi_validate.sh`, exit 77 when the validator is missing). Swagger UI integrity hashes are for `swagger-ui-dist@5.17.14`.

**Why.**
- `schemaName!T = T.stringof` (`openapi.d:156`): two `User` structs from different modules collide silently (the
  second reuses the first schema), and template instances such as `Page!(User)` produce component names the spec
  forbids (they must match `^[a-zA-Z0-9.\-_]+$`).
- `WithStatus!T` is documented as 200 (`openapi.d:292`), so `createUser` returns 201 but its docs say 200. Error
  responses (`HttpError` 404, 401...) cannot be declared at all.
- `operationId` is the function name, so two handlers named `list` in different controllers get the same
  `operationId`, which the spec forbids.
- `docsHtml` inserts the title into HTML without escaping, and loads Swagger UI from a CDN without Subresource
  Integrity.

**Change (P7).**
1. Schema names:
   - plain structs use `__traits(identifier, T)`;
   - template instances use the template's name, `_`, then the arguments' names (`Page_User`);
   - any character outside `[A-Za-z0-9._-]` becomes `_`.

   `Components` records each name's owner, using `__traits(fullyQualifiedName, T)` (it works on LDC 1.40). When a
   different type wants a name that is already taken, it gets its sanitized fully qualified name (`app.models.User`).
   A new `@schemaName("UserOut")` attribute overrides the name.
2. `@status(201)` attribute on handlers and controller methods:
   - it sets the success status: `dispatch` assigns it after a normal return unless the handler returned `WithStatus`
     or `Response`, which win;
   - on a `void` handler it replaces 204;
   - OpenAPI documents that code;
   - `WithStatus!T` without `@status` is documented as `"2XX"` (OpenAPI 3.0 allows range keys);
   - `handlerError` rejects values outside 100–599, and `@status(204)` with a non-void return ("a 204 response has no
     body; return void"). Add `tests/compile_fail/` cases for both.
3. `@responds(404, "User not found")`, repeatable, adds a response entry with
   `{"$ref":"#/components/schemas/HTTPError"}`, where `HTTPError` is
   `{"type":"object","properties":{"detail":{"type":"string"}},"required":["detail"]}`, the shape `renderError`
   produces.
4. `operationId`: the function name; on a duplicate in the same document, append `_<method>_<sanitized path>`.
5. `docsHtml`: HTML-escape the title (`& < > " '`). Add `integrity="sha384-..."` and `crossorigin="anonymous"` to the
   pinned `swagger-ui-dist@5.17.14` files; compute the hashes from the files and leave a comment on how to recompute
   them. Add `OpenApiInfo.swaggerUiBase` for self-hosting (default: the CDN).

**Tests** (`tests/web/openapi.d`): two same-named structs from two modules, a template struct, `@status` both in
`dispatch` and in the document, `@responds`, a duplicate `operationId`, title escaping. In CI, validate the generated
document with `openapi-spec-validator` (exit 77 when it is not installed).

**Note.** `check.sh` runs every file directly inside `tests/web/` as a program
(`for t in tests/web/*.d; ... -main -run`). Helper modules for these tests must live in a subfolder, such as
`tests/web/support/`.

### [x] 1.9 Errors inside handlers (D4) — M

> **Done.** Fiber stack default is 256 KiB (512 KiB cost ~0.8 MB RSS on LDC at 1,000 in-flight requests; 256 KiB measured the same as 128 KiB). The optional SIGSEGV report is implemented (`onCrash` in `epoll.d`, checked by `tools/crash_check.sh`). `App.logStackTraces` defaults to true, limited to 5 traces per second per App.

**Why.**
- `Worker.run` (`engine/.../epoll.d:169–190`) catches every `Throwable`, logs only `t.msg` (no file, line or stack
  trace), answers 500, and reuses the fiber together with its `Context` and `Locals`, even though after an `Error` D
  does not guarantee that cleanup code ran.
- `App.logError` (`application.d:383`) logs the message and file:line for exceptions, but no stack trace.
- Fiber stacks are 128 KiB (`ServerConfig.fiberStackBytes`). An overflow is a SIGSEGV that kills the whole process,
  every worker included, with no hint about the cause.

**Change.**
1. `Worker.run`: on any `Throwable` other than `RequestCancelled`:
   - set `failed = true`, and `poisoned = true` when it is not an `Exception`;
   - log `t.toString()` (message, file:line and stack trace) together with the method and path;
   - rate-limit: at most 5 full traces per second per worker. The rest are counted and reported in the next line, e.g.
     `vela: 37 more handler failures in the last second (traces suppressed)`.
2. `releaseWorker`: a poisoned worker is always retired, the same way as the `maxIdleWorkers` branch
   (`retiring = true; call(); destroy`), and is never put back in the idle pool. Its `Context` goes with it.
   `finishH2` follows the same path. Add `handlerErrors` and `fibersPoisoned` to `LoopStats`.
3. `App.logError` for exceptions that are not `HttpError`: include `e.toString()`, behind the same kind of rate limit
   (one limiter per App, which after Phase 2 means per worker). Add `App.logStackTraces = true`. Stack traces need
   debug info for symbol names: document the build flag (`-g`, or DUB's `release-debug` build type) after checking the
   actual output on both compilers.
4. Fiber stack size:
   - D fiber stacks are mmap'd and only touched pages count toward RSS, so a bigger default is almost free.
   - Try 512 KiB; keep it if the memory tests show no change beyond noise, otherwise use 256 KiB.
   - Each fiber uses 2 memory mappings (stack and guard page). Write the `vm.max_map_count` limit (65,530 by default,
     about 32k fibers per process) into the `fiberStackBytes` comment.
5. Optional, nice to have (`@system`, in `epoll.d`): a SIGSEGV handler on an alternate signal stack (`sigaltstack` for
   each worker thread):
   - it reads a thread-local pointer to the current Worker, set in `resume`;
   - it writes, with `write(2)` only and no allocation, a line like
     `vela: segmentation fault while running GET /path; if the handler recurses deeply or keeps large arrays on the stack, raise ServerConfig.fiberStackBytes (now N KiB)`;
   - then it restores the default action and re-raises, so a core dump still happens.

**Tests.**
- `tests/net/epoll_net.d`:
  - a handler indexing out of bounds in `@safe` code (a `RangeError`) → 500, the connection is closed, the next request
    runs on a different fiber, and `fibersPoisoned == 1`;
  - stderr contains file:line;
  - 50 failing requests in a burst → at most 5 traces plus a summary line.
- `tests/net/h2_net.d`: the same over HTTP/2.
- If item 5 is done: a child server process with a deeply recursive handler (run with `ulimit -c 0`) dies by SIGSEGV
  with the message on stderr.

### [x] 1.10 An unsound `@trusted` accessor — S

**Why.** `examples/api/source/app.d` (around line 36) has `ref Config config() @trusted => gConfig;`, a **mutable**
reference to `__gshared` data. Any `@safe` code can write it while workers read it, which is a data race in `@safe`
code. `AGENTS.md`'s rule ("read it through a small `@trusted` accessor") does not say the accessor must be read-only.

**Change.**
- Make it `ref const(Config) config() @trusted`, with writes through a separate `@system void setConfig(Config)` that
  `main` calls before `serve`.
- Extend the `AGENTS.md` rule: "the accessor returns const or immutable data, never a mutable ref".
- Look for other cases with `grep -rn "ref .*@trusted" --include=*.d .`.

### [x] 1.11 Small `TestClient` additions — S

**Change.**
- Add `patch`, `head`, `options` and a general `request(Method, target, body, headers...)`.
- Add `TestResponse.headers(name)`, returning every value (`header(name)` keeps returning the first).

Full parity with what the server sends comes in 4.6.

---

## Phase 2 — One App per worker

**Background.**
- Today `serve(app, cfg)` passes a single `App` to `handlerFactory(app)` (`source/vela/server.d:36–52`), and every
  worker thread's fibers call into that same object.
- Anything a handler captures (closures, controllers) runs on all threads at once with no synchronization. The hello
  example's `StatsController.hits++` (`examples/hello/source/app.d:113`) only works because `main` sets
  `cfg.workers = 1` (line 163). `serveOpenApi` writes its lazily built string from several threads (fixed by 1.7).
- Module-level variables, in contrast, are thread-local, so each worker silently has its own copy.

After this phase there is one rule (D1): **everything the build function creates belongs to one worker.**

**About the GC (measured during the review).** With 4 threads allocating 40-byte strings at once in one process, total
throughput was about 11 times worse than ideal parallel scaling: the threads share one GC lock and trigger collections
together. A per-worker App does not change that (one process, one GC). Keeping the framework's hot path GC-free
(`tests/alloc`) therefore stays essential. If apps that allocate heavily show GC contention, process-per-core is the
alternative, parked in Phase 7.

### [x] 2.1 The `serve(build)` API — S

> **Done.** Also added `tryServe` (same arguments, returns false instead of exiting), which the tests use; `serve` calls it and exits with 1 on failure. Lambdas without captures resolve to the `function` overloads, with captures to the `delegate` ones.

```d
// source/vela/server.d
void serve(App delegate() @system build, ServerConfig cfg);
void serve(App delegate() @system build, ushort port = 8080);
void serve(App function() @system build, ServerConfig cfg);
void serve(App function() @system build, ushort port = 8080);
```

```d
App buildApp()
{
    auto app = new App;
    app.get!("/users/{id}", getUser);
    return app;
}

void main() { serve(&buildApp, 8080); }
```

- The build callback is `@system`, following the safety model: user callbacks accept `@system` code. It is called
  from a single `@trusted` site, `callBuild`, with the standard comment. Add it to `AGENTS.md`'s list of call sites.
- Remove the `serve(App, ...)` overloads (P2).
- If the build function returns an `App` it already returned for another worker (for example `serve(() => app)`),
  startup fails with
  `vela: the build function must create a new App for each worker (it returned the same object twice); move \`new App\` and the route registration inside it`.

### [x] 2.2 Engine: per-worker initialization — M

> **Done.** `runEpollServer(cfg, WorkerInit)` returns a flag: false for a bad TLS config, a build that threw, or a listener that could not bind (`EpollLoop.everListened`). A later worker's failed build stops all loops. `App.freeze` is called in `server.d` right after each build.

- Add `alias WorkerInit = HandlerFactory delegate() @safe;` in `vela.engine.loop`. `runEpollServer(ServerConfig, WorkerInit)`
  calls `init()` **on each worker's own thread**, before that worker opens its listener. That way the App's
  thread-local state, `pgPool` and `httpClient` all belong to that thread. The simplest place is the thread lambda in
  `startWorker` (`epoll.d`, around line 1880): `{ auto f = init(); lp.run(cfg, f); }`. The `EventLoop.run` interface
  does not change.
- Startup order and failures:
  - Worker 0 runs on the main thread (`gLoops[0].run(...)`). Call its `init()` **before** starting the other threads.
    If the build function throws (a `RouteError`, for example), print one line,
    `vela: building the app failed: <msg> (<file>:<line>)`, and start nothing.
  - If a later worker's build throws, log one line, stop all loops through the existing stop path, and report failure.
  - `runEpollServer` returns a success flag; only `server.d` turns a failure into `exit(1)`, so tests can drive the
    engine without the process exiting.
- `server.d` calls `app.freeze()` (from 1.7) right after each build.
- The dev server (non-Linux) builds once.
- The duplicate-App detection from 2.1 lives in `server.d`: a startup-only list of the returned objects, guarded by a
  `core.sync.mutex.Mutex`.

### [x] 2.3 Migrate every call site — S

Change these to `serve(&buildApp, ...)` or `serve(() { ... }, ...)`:
- `README.md:24,155`
- `docs/quickstart.md:44,128,211`
- `docs/deploy.md:39`
- `examples/hello/source/app.d:164`
- `examples/api/source/app.d:228`
- `tests/net/browser_serve.d:75`, `tests/net/h2_serve.d:52`, `tests/net/serve_slow.d:40`

`examples/hello` keeps its in-memory store and `cfg.workers = 1`, with a rewritten comment: each worker builds its own
App and has its own module variables, so this in-memory store would be per worker; the example runs one worker, and
with a real database you leave `workers = 0`.

### [x] 2.4 Docs and tests — S/M

> **Done.** `tests/net/workers_net.d` (run by `check.sh`). The duplicate-App message reaches stderr as `vela: building the app failed: vela: the build function must create a new App ...`.

- Add a "Workers and state" section to `docs/quickstart.md`:
  - the per-worker rule;
  - how to share state: a database, or `__gshared` data plus a `core.sync.mutex.Mutex` behind a `@trusted` accessor,
    with short critical sections and **never** an I/O wait while holding the lock;
  - total database connections = workers × `PgConfig.maxConns`.
- Update the concurrency section of `AGENTS.md`.
- Tests in `tests/net/epoll_net.d`, driving the engine directly:
  - with 4 workers, the build runs 4 times on 4 different threads (record `Thread.getThis` under a mutex);
  - a per-worker counter: N requests over several connections, the counters sum to N, and each App is only ever
    touched by one thread;
  - a build that returns the same App twice fails with the message from 2.1;
  - a build that throws produces the one-line message and a failure flag.

---

## Phase 3 — Memory-safe request data

**Background (verified, see Appendix A).** `Header!"X"` (`web/.../params.d`), `const(char)[]` parameters,
`Request.header()` and `Request.body` are slices into network buffers:
- the HTTP/1 connection buffer from `BufferPool` (`engine/.../bufferpool.d`, malloc'd; oversize buffers are freed as
  soon as the request is done, pooled ones are reused);
- `ByteBuffer`s (`http/.../buffer.d`, malloc/realloc/free), which hold HTTP/2 header and body data
  (`H2Stream.fieldBytes`, `H2Stream.body` in `h2.d`).

A `@safe` handler can store one of these slices: `const(char)[] leaked; string keep(Header!"X-Tok" t) { leaked = t; ... }`
compiles. Reading it later is a use-after-free. The response side has the same problem: `ctx.response.body.data` is a
slice into malloc'd memory that a later `realloc` invalidates.

**Target model (D2).**
- Every slice vela hands to user code points into **GC-owned** memory. A slice kept after the request is memory-safe:
  it keeps its memory block alive. It may show bytes from a later request on the same connection or stream. That is
  documented, and it is a logic bug in user code, not memory corruption.
- `Header!"X"` holds a **copied `string`**, so the common case (keeping a token or another header value) is correct,
  not merely safe.
- `const(char)[]` parameters stay zero-copy views, as an explicit opt-in; `string` parameters copy, as they already do.
- The hot path stays GC-free after warm-up, because buffers are still pooled. New garbage appears only for bodies above
  64 KiB and when a buffer grows.

### [x] 3.1 `BufferPool` on the GC — S

> **Done.** `allocBlock` in `vela.http.buffer` is the one place that calls `GC.malloc(NO_SCAN)` (through a function-pointer cast that adds `@nogc`; `GC.malloc` is `extern (C)`, and a cast without that fails at run time on DMD).

- `acquire`: `GC.malloc(size, GC.BlkAttr.NO_SCAN)`, wrapped in a small `@trusted` helper that returns `ubyte[]`.
  **Never** use `NO_INTERIOR`: user slices point into the middle of the block.
- `release`: oversize buffers, and buffers above the cache ceiling, just drop their reference. Never free them, since
  someone may still hold a slice; the GC reclaims them once unreferenced. Pooled buffers stay as today.
- Remove the destructor's `free` loop. `compact` (a `memmove` inside the same block) stays.
- Remove `@trusted` where the code is now plainly `@safe`, and fix the comments that say "outside the GC heap".

### [x] 3.2 `ByteBuffer` on the GC — M

> **Done.** HPACK audit: the decoder's dynamic table is internal and its sink slices are `scope`; request-visible bytes always come from the stream's `fieldBytes`/`body`. `ClientResponse.headers` are `idup` copies.

- `reserve`: allocate a new `NO_SCAN` block of the new capacity, copy, and drop the old one. No `realloc` and no
  `free`: an old slice may still be read. `shrinkTo` drops the block; the destructor does nothing. `@disable this(this)`
  stays (one owner for writes).
- This covers response bodies (`ctx.response.body`), the HTTP/2 stream buffers (`fieldBytes`, `body`, `response`),
  worker output, the HPACK output buffer and the HTTP/2 outbox.
- Audit the HPACK decoder (`hpack.d:3` says its dynamic table lives "outside the GC heap"). Confirm that decoded names
  and values handed to `Request` are always copied into the stream's `fieldBytes` and never point into the table. Copy
  any path that does.
- Audit every producer of `Request` slices: `parseRequestHead` (the connection buffer), HTTP/2 `finishRequest`, and TLS
  reads (also into the connection buffer). Check that the HTTP client's `ClientResponse.headers` are copies (its body is
  already a `string`).
- Item 4.2 changes `H2Session.respond`, which swaps `ByteBuffer`s between the worker and the stream. Keep that working
  here.

### [x] 3.3 `Header!"X"` copies — S

- Change `Header`'s field to `string value`. In `dispatch` (`handler_traits.d`, the `Header!n` branch and the
  `Optional!(Header!n)` branch), use `args[i].value = hv.idup;`. OpenAPI does not change.
- Replace the "copy with `.idup`" advice with the new model in `params.d`, the README pitfalls, `AGENTS.md` and
  `docs/quickstart.md`. Simplify `trace.get.idup` in `examples/hello`.

### [x] 3.4 Memory checks — S/M

> **Done.** Numbers (peak RSS, 1,000 in-flight): HTTP/1.1 DMD 25.2 MB / LDC 27.1 MB (limit 30; run-to-run noise is about ±1.5 MB); h2 16.7 / 20.6 MB; HTTPS h1 68.3 / 70.9 MB and h2 54.6 / 57.5 MB (limit moved to 80 MB: the GC holds the same 1,000 buffers in ~3 MB more than the malloc heap did, HTTP/1.1 over TLS only). New `s_memory_uploads`: 200 uploads of 512 KiB peak at ~110 MB and fall to ~41 MB three seconds after the burst. Getting there needed more than the plan's options: the GC returns a pool to the OS only when it is entirely free, so `trimIfQuiet` now also retires the idle workers and drops the buffer cache before `GC.collect()`/`GC.minimize()`, and `releaseWorker` clears `Worker.req`/`Worker.store`, `server.d` clears `ctx.request` (stale slices pinned whole buffers).

- Run the memory section of `check.sh` on both compilers before and after, and record the numbers in the commit
  message. Limits: 30 MB for HTTP/1.1 and HTTP/2, 56 MB for HTTPS.
- New memory test for the garbage path: 200 concurrent 512 KiB uploads (above the 64 KiB class). Record the peak, then
  enforce it with some margin; RSS must come back down after the burst (`trimAfterBurst` runs `GC.collect` and
  `GC.minimize`).
- If RSS regresses:
  - (a) let the loop trigger a collection once the oversize bytes dropped since the last collection exceed
    `max(8 MiB, 4 × maxBodyBytes)` and the worker is quiet;
  - (b) lower `maxCachedBytes`.

  Do **not** go back to malloc/free for anything that user code can reach.
- The allocation tests must still report 0 bytes. Compare h1 and h2 loadgen throughput before and after; this is for
  information, not a gate.

### [x] 3.5 Tests and docs — S

> **Done.** `testKeptSlices` (HTTP/1.1, 2,000 requests, 200 KiB bodies) and `testKeptSlicesOverH2` (400 streams).

- `tests/net/epoll_net.d` and `tests/net/h2_net.d`: for 2,000 requests on keep-alive connections, a handler stores in
  module-level arrays:
  - a `const(char)[]` path parameter;
  - `ctx.request.header("X-A")`;
  - a `Header!"X-B"` value;
  - the raw body slice of a 200 KiB body (the oversize path);
  - and a middleware stores `ctx.response.body.data` after the handler.

  Afterwards, touch every byte of every stored slice. Expected: no crash, the lengths are unchanged, and every
  `Header!"X-B"` value still equals what was sent (copy semantics).
- `AGENTS.md`, Safety model section: add a paragraph on the memory model ("request data handed to user code lives in
  GC memory; a kept view is memory-safe but may change"), and update the pitfalls. Also update the README and the
  quickstart table.

---

## Phase 4 — Streaming responses

**Background.**
- The engine contract `RequestCallback = void delegate(ref Request req, ref ByteBuffer output)`
  (`engine/.../loop.d:21`) requires the whole response, serialized as HTTP/1.1 text, before anything is sent.
- `server.d` builds that text (`source/vela/server.d:40–51`), and for HTTP/2 the session parses it back into `:status`
  and fields (`h2.d`, `queueResponse`).

Consequences:
- no Server-Sent Events and no token streaming (LLM-style responses);
- no large downloads: static files are read whole into memory, up to `StaticConfig.maxFileBytes` = 16 MiB;
- no path to WebSockets;
- an HTTP/1.1 text detour on every HTTP/2 response.

**Target design.**

```d
// vela.http.response — no I/O; shared by the web layer and the engine
struct ResponseHead
{
    int status = 200;
    const(char)[] contentType;        // null = no Content-Type
    const(HeaderField)[] headers;     // already validated by the web layer (1.1)
    long contentLength = -1;          // -1 = unknown (streamed)
}

/// Where a response goes. Implemented by the engine (one per in-flight request) and by TestClient.
interface ResponseSink
{
@safe:
    /// Commits status and headers. Exactly once, before any write.
    void start(ref const ResponseHead head);
    /// Appends body bytes (copied). May suspend the fiber while the client is slow (backpressure).
    /// Throws RequestCancelled if the client is gone.
    void write(scope const(char)[] data);
    /// Sends what is buffered now and waits until the transport accepted it (one SSE event).
    void flush();
    /// Ends the body. With contentLength >= 0, exactly that many bytes must have been written.
    void end();
}

// vela.engine.loop
alias RequestCallback = void delegate(ref Request req, ResponseSink sink) @safe;
```

**How the engine frames a response.**

| Case | Wire format |
|------|-------------|
| HTTP/1.1, known length | `Content-Length`, then the body as is |
| HTTP/1.1, unknown length | `Transfer-Encoding: chunked`; each `write` is one chunk; `end` writes `0\r\n\r\n` |
| HTTP/1.0 client, unknown length | no chunked encoding; `Connection: close`; `end` closes the connection |
| HEAD, 204, 304 | head only; the engine discards writes (the web layer does not run stream bodies for HEAD, see 4.5) |
| HTTP/2 | HEADERS from the structured head (no re-parsing); DATA frames as the windows allow; END_STREAM at `end`, or on HEADERS when there is no body |

**Backpressure.** The engine buffers up to `ServerConfig.streamHighWaterBytes` (64 KiB by default) per response. Above
that, `write` tries to send. If the socket (HTTP/1) or the flow-control windows and outbox (HTTP/2) do not accept the
data, the fiber waits for EPOLLOUT, a WINDOW_UPDATE or the outbox to drain, with `writeTimeoutMs` as the deadline.
Passing the deadline cancels the request and closes the connection.

**Deadlines.** `requestTimeoutMs` applies until `start`. For unknown-length responses it is disarmed at `start`, so
long-lived SSE connections are possible. After that, `writeTimeoutMs` applies to each blocked write, and an optional
`ServerConfig.streamTimeoutMs` (0 = no limit) applies to the whole stream.

**Errors after `start`.** The head is already on the wire, so a 500 is impossible. HTTP/1.1 closes the connection
without the terminating chunk, so the client sees a truncated body. HTTP/2 sends `RST_STREAM(INTERNAL_ERROR)`. Either
way the error is logged with 1.9's rate limiter.

**Limits.** A streaming response holds a fiber and counts toward `maxInFlight` (per worker), so 1,024 SSE clients fill
one worker's default limit. Document this. A separate limit for streams belongs in Phase 7.

**WebSockets later.** Keep room in the sink design for a future connection takeover, but do not implement it.

### [x] 4.1 Structured head and sink, buffered only (no behavior change) — M

> **Done.** `vela.http.response` has `ResponseHead`, `ResponseSink`, `BufferedSink`, `isHopByHop`, `statusHasNoBody` and `ResponseAborted`; the old six-argument `writeResponseHead` stays as a thin wrapper for the engine's own error responses. `Request.http11` is new (set by the parser, true for HTTP/2) so HTTP/1.0 clients get close-delimited bodies. Starting a response disarms `requestTimeoutMs`; each blocked write has `writeTimeoutMs`, and `ServerConfig.streamTimeoutMs`/`streamHighWaterBytes` are new.

- Add `vela.http.response` with `ResponseHead`, `ResponseSink`, and an HTTP/1 serializer
  `writeResponseHead(ref ByteBuffer, ref const ResponseHead, bool keepAlive, bool chunked)`.
- `RequestCallback` takes `(ref Request, ResponseSink)`. `server.d`, after `app.handle(ctx)`:
  - builds a `ResponseHead` from `ctx.response`, with `contentLength = body.length`;
  - calls `sink.start(head)`, `sink.write(body)` (skipped for HEAD, 204 and 304), then `sink.end()`.
- Engine: one buffered sink per Worker, created once per fiber and reused (no per-request GC), writing into
  `w.output` exactly as today. The HTTP/1 path sends the same bytes with the same syscalls as before. The HTTP/2 path
  still builds HTTP/1 text for `H2Session.respond` in this step; 4.2 removes it.
- Responses the engine produces itself (413, 431, 503, 504, 500, the redirect port, `100 Continue`) use the same
  serializer.

**Done when.** Every test is green, the allocation tests report 0 bytes, memory numbers are unchanged, and h2spec is
unchanged.

### [x] 4.2 HTTP/2 encodes from `ResponseHead` — M

> **Done.** The HTTP/1 re-parser is gone: `H2Session.respond(stream, head, body)`. `tests/h2/session_test.d` keeps describing responses as HTTP/1.1 text through a small helper (`respondH1`) that builds the head; `respondCopy` and `writeResponseHeadMinimal` were removed. h2spec stays at 146/146 over TLS and 145/146 in cleartext.

- `H2Session.respond(H2Stream s, ref const ResponseHead head, ref ByteBuffer body)` replaces the HTTP/1-text version.
  HEADERS are encoded straight from the head, with names lowercased and hop-by-hop headers dropped defensively (1.1
  already removes them).
- Delete the HTTP/1 re-parser in `queueResponse`. Replace `writeResponseHeadMinimal` with a minimal structured head for
  the early statuses.
- Update `tests/h2/session_test.d`, the fuzz harness (`tests/fuzz/fuzz_h2.d`, `h2_invariants.d`) and
  `tests/alloc/h2_hot_path.d`.
- HTTP/2 is frozen (D3), but this change is required: run `tools/h2_interop.sh` (146/146 and 145/146) and
  `tools/fuzz.sh 300 h2`.

### [x] 4.3 Streaming over HTTP/1.1 — M/L

> **Done.** `Worker` implements the sink; `waitWritable` waits for the connection's EPOLLOUT edge (not `awaitFd`, which would replace the connection's epoll registration). A large single `write` is sent from the caller's memory without a copy. Tests: `tests/net/stream_net.d`, `tools/stream_interop.sh` (`curl -N`).

- The engine's sink accepts unknown lengths, using chunked framing.
- While a response is streaming, the connection is in a new state:
  - EPOLLOUT resumes the worker if it is blocked in `write` or `flush` (a new wait reason in `Worker`);
  - EPOLLRDHUP, HUP and ERR cancel it through the existing `cancelRequest` path;
  - the next pipelined request is not parsed until `end()`.
- Deadlines as described above. Add `LoopStats.streams`.

**Tests** (new `tests/net/stream_net.d`):
- the chunked framing is byte-exact;
- 10 MiB streamed to a slow reader keeps RSS bounded (peak under baseline + 2 × the high-water mark per connection);
- a client that disconnects mid-stream: the handler gets `RequestCancelled` at its next `write` or `sleep`, and its
  `scope(exit)` runs;
- a reader that stops reading is closed after `writeTimeoutMs`;
- an HTTP/1.0 client gets a close-delimited body;
- HEAD on a stream route returns the head only;
- an error after `start` produces a truncated chunked body and a log line;
- keep-alive after a finished stream (the next request on the same connection works);
- a pipelined request queued behind a stream waits for it.

Add a `curl -N` check, in a new `tools/stream_interop.sh` rather than the frozen `h2_interop.sh`.

### [x] 4.4 Streaming over HTTP/2 — M/L

> **Done.** `H2Session.beginResponse/sendData/endResponse/pendingBytes`; the stream is committed lazily at the high-water mark or on `flush`. Handlers suspended on a full stream wake from `wakeH2Writers` (end of `flushH2`/`driveH2`). Graceful stop: GOAWAY first, then `shutdownGraceMs`, then teardown cancels the handlers (tested). Fuzzers updated; `tools/fuzz.sh` ran on both targets.

- `H2Session` gains `beginResponse(s, head)`, `sendData(s, data)` (which returns whether the stream is above its
  high-water mark) and `endResponse(s)`.
- The engine suspends the worker when `sendData` reports above the high-water mark, and resumes it on a WINDOW_UPDATE
  or when that stream's output drains. A `RST_STREAM` from the client cancels it, as today.
- Graceful stop must not wait forever for an SSE stream: cancel streaming responses still open after `shutdownGraceMs`,
  then send GOAWAY as today.

**Tests.**
- Session tests: interleaved streams, flow control with a 1-byte window, END_STREAM placement, `RST_STREAM` in the
  middle of a stream, GOAWAY while streams are open.
- `tests/net/h2_net.d`: multiplexed streams with a slow reader.
- Update the fuzz harness. Run h2spec and `tools/fuzz.sh 300 h2`.

### [x] 4.5 Web API: `Stream` and `EventStream` — M

> **Done.** `web/.../stream.d`. `Stream.contentLength` (optional) lets a stream announce its length, which `serveStatic` uses. `@produces("text/csv")` is implemented. `RouteError`-style misuse of `EventWriter` (CR/LF in event name or id) throws a plain `Exception`, which aborts the stream.

```d
/// A streamed body.
///     return Stream("text/csv", (scope StreamWriter w) { foreach (r; rows) w.write(r); });
struct Stream
{
    const(char)[] contentType = "application/octet-stream";
    void delegate(scope StreamWriter w) @system body;
}

struct StreamWriter
{
    void write(scope const(char)[] s);   // may suspend while the client is slow
    void flush();
}

/// Server-Sent Events.
///     return EventStream((scope EventWriter w) { w.send("hello"); sleep(1.seconds); w.send("again"); });
struct EventStream
{
    void delegate(scope EventWriter w) @system body;
}

struct EventWriter
{
    /// Writes "event:" and "id:" when given, one "data:" line per line of `data`, a blank line, then flushes.
    void send(scope const(char)[] data, scope const(char)[] event = null, scope const(char)[] id = null);
    void comment(scope const(char)[] text = null);   // ": text" heartbeat; flushes
    void retry(uint ms);
}
```

- Handlers may return `Stream`, `EventStream` or `WithStatus!Stream`. Add them to `isSupportedReturn`, and list them in
  the `handlerError` message about return types.
- Where the body runs (P6): **inside `dispatch`**, so middleware wraps the whole stream. The access log then measures
  the full duration, and `scope(exit)` blocks in middleware run after the stream ends.
- **Lazy commit:** the head is sent on the first `write`, `flush` or `end`, or when the body returns. A handler that
  throws before writing anything still gets a normal error response.
  - At commit time: validate the headers (1.1), call `ctx.sink.start` with `contentLength = -1`, and set
    `ctx.response.committed = true`.
  - `EventStream` adds `Content-Type: text/event-stream`, `Cache-Control: no-cache` and `X-Accel-Buffering: no`.
  - After the commit, `setHeader`/`addHeader` log once (`vela: header 'X' set after the response started; ignored`)
    and do nothing, and `App.fail` aborts the response (see "Errors after `start`") instead of rendering an error.
- `EventWriter`: an event name or id containing CR or LF is a programming error, so abort the stream.
- The user's body delegate is called from one new `@trusted` site, `callStream`. Add it to `AGENTS.md`'s list.
- HEAD: send the head and do not run the body.
- `Context` receives the sink through `ctx.reset(req, sink)`. `TestClient` passes a sink that records chunks.
- OpenAPI: `Stream` is documented as 200 with `application/octet-stream` (an optional `@produces("text/csv")` attribute
  can override it); `EventStream` as `text/event-stream` with a string schema.

**Tests** (new `tests/web/stream.d`, with `TestClient`):
- chunks are recorded in order;
- SSE formatting: multi-line data becomes several `data:` lines; an event name with CR/LF aborts;
- a header set after the commit is ignored and logged;
- an exception before the first write gives a normal 500; an exception after it aborts.

### [x] 4.6 `TestClient` sees what clients see — S

> **Done.** The shared step is `sendResponse(ctx)` (called by `server.d` and `TestClient`) plus `checkResponse` (owned headers, validation, `Date`). `TestResponse` gained `chunks`, `date`, `contentLength` and `aborted`; HEAD/204/304 bodies are empty in tests too.

Move the response finalization out of `server.d` into one web-layer function that both `server.d` and `TestClient`
call: the `Date` header, no body for HEAD, no body for 204/304, and header validation. `TestClient` then matches what
clients receive, except for transport framing. `TestResponse` gains `chunks` (for streams) and `date`.

### [x] 4.7 Stream large static files — M

> **Done.** `maxFileBytes` default is now 1 GiB (a cap, not a memory limit). No read-ahead: each 64 KiB piece is read through `offload` and then written (`offload` suspends the fiber, so overlapping needs futures that do not exist yet). Test: a 50 MiB file to a slow reader stays within +12 MB.

- Files above `StaticConfig.offloadAbove` (256 KiB) are sent in 64 KiB chunks with a known `Content-Length` (the file
  size), so backpressure applies. Reads go through `offload`, either one chunk at a time or reading ahead into two
  buffers.
- `maxFileBytes` stays as a safety cap with a much larger default (decide: 1 GiB, or 0 = no limit), since memory no
  longer grows with file size. ETag, 304 and Last-Modified keep working.
- Range requests (206) are parked (Phase 7).

**Tests.** `tests/web/static_files.d` (`TestClient`), plus a network test downloading a 50 MiB file with a slow
reader, whose RSS must stay bounded.

### [x] 4.8 Docs — S

- README: add streaming to the feature list.
- `docs/quickstart.md`: a new "Streaming and Server-Sent Events" section. The example uses a loop with `sleep`; the HTTP
  client cannot stream upstream responses yet (parked).
- `AGENTS.md`: the new engine contract, and that a stream counts toward `maxInFlight`.
- `docs/deploy.md`: proxy buffering (`X-Accel-Buffering`) for anyone who does put a proxy in front.

---

## Phase 5 — Missing basics

### [x] 5.1 The client's address — M

> **Done.** `vela.http.ip` (parse, format, CIDR; IPv6-ready). `Request.peer` is set by the engine for both protocols. `ServerConfig.trustedProxies` is validated in `tryServe` and handed to each worker's App (`App.trustProxies`). An invalid entry in the header returns the peer; all hops trusted returns the leftmost. `TestClient.from("ip")` sets the peer. `accessLog` prints `ip=`.

**Why.** `Conn.peerIp` (IPv4, recorded at accept in `epoll.d`) is only used for connection logs. Handlers cannot see the
client's address (the README says so), which blocks rate limiting, audit logs and abuse handling.

**Change.**
- Add `Request.peer`, of type `IpAddress`: a `vela.http` struct holding the family, `ubyte[16]` and the port, with a
  `toString` that formats into a caller-supplied buffer (no allocation). It is IPv6-ready even though IPv6 listeners
  stay out of scope.
- The engine sets it for HTTP/1 (`startRequest`) and for HTTP/2 (when a stream is handed to a worker). This follows the
  every-producer rule, but the parser is untouched: the address does not come from the bytes.
- Trusted proxies:
  - `ServerConfig.trustedProxies`: CIDR strings, parsed at startup; an invalid one fails startup with a one-line
    message;
  - `ServerConfig.forwardedHeader = "X-Forwarded-For"`;
  - `ctx.clientIp()`: if the peer is trusted, walk the header from the right, skipping trusted addresses, and return
    the first untrusted one (an invalid entry stops the walk and returns the peer); otherwise return the peer.
    Supporting RFC 7239's `Forwarded: for=` is optional.
- New parameter kind `ClientIp ip`. Follow the "new handler parameter kind" checklist in `AGENTS.md`: `params.d`,
  binding in `handler_traits.d` (dispatch and `handlerError`), not shown in OpenAPI, tests, and a `tests/compile_fail/`
  case for misuse (for example `Optional!ClientIp`).
- `accessLog` prints the client IP.

**Tests.**
- `TestClient` gains a `peer` option. Cover trusted and untrusted proxy chains, and an `X-Forwarded-For` from an
  untrusted peer, which must be ignored.
- Network tests: the real peer `127.0.0.1` is seen over HTTP/1.1, h2c and TLS.

### [x] 5.2 Chunked request bodies — M/L

> **Done.** `vela.http.chunked.ChunkedDecoder` decodes in place and compacts, so the pipelined request after the body sits right behind it and the engine's `compact(c.total)` works unchanged. A second `Transfer-Encoding`, any coding but a lone `chunked`, or HTTP/1.0 are refused (400/501); Content-Length next to TE stays 400 (decided after all headers, so obfuscated TE + CL is still 400). Fuzz invariants include split-independence of the decoder; `tools/fuzz.sh 300 parse` ran clean.

**Why.** The parser answers 501 to any `Transfer-Encoding` (`http/.../parser.d`, `if (sawTE) return fail(501)`). Many
clients send chunked uploads when they do not know the length in advance: `curl -T -` from stdin, some HTTP libraries
and proxies.

**Change.**
- Parser:
  - accept `Transfer-Encoding: chunked` only (case-insensitive, as the only coding);
  - any other coding → 501; `Transfer-Encoding` together with `Content-Length` → 400 (unchanged);
  - add `HeadResult.chunked`.
- New pure, fuzzable decoder `vela.http.chunked.ChunkedDecoder`:
  - incremental and in place: it moves chunk payloads toward the start of the body region, so the decoded body ends up
    contiguous in the same buffer;
  - hex chunk sizes with an overflow check; extensions are ignored (with a length bound); trailer fields are parsed
    and discarded (bounded by `maxHeadBytes`);
  - CRLF strictly required;
  - total over `maxBodyBytes` → 413; anything malformed → 400.
- Engine (`tryParse`, `fill`):
  - grow the buffer as data arrives, up to `maxBodyBytes`; `100-continue` works as today;
  - deadline: `headerTimeoutMs` for the head, then the same value as a no-progress limit while the body arrives;
  - bytes after the last chunk stay in the buffer for the next pipelined request.
- `Request.body` is the decoded body.
- Remove "chunked request bodies" from the README limits and from `AGENTS.md`'s out-of-scope list.

**Tests.**
- Corpus files `tests/fuzz/corpus/<name>.<ok|incomplete|status>.http`: valid bodies, extensions, trailers, a huge size,
  a negative size, a missing CRLF, `Transfer-Encoding: chunked, identity`, whitespace and tab variants, two
  `Transfer-Encoding` headers.
- Add invariants in `tests/fuzz/invariants.d`.
- `tests/net/epoll_net.d`: a chunked upload, `100-continue` with chunked, slow chunks, over `maxBodyBytes` → 413, a
  pipelined request after a chunked body.
- `tools/fuzz.sh 300 parse`.

### [x] 5.3 List query parameters — S/M

> **Done.** `Request.queryValues(name)`; errors carry the element index (`["query","ids",1]`).

- An array of scalars outside the route (`string[] tags`, `int[] ids`) receives every value of a repeated key
  (`?tag=a&tag=b`). When absent it is an empty array, not an error; document that.
- Add `Request.queryValues(name)`, an allocation-free iterator (a small struct with `front`/`popFront`; no `std.range`).
- `handlerError`:
  - arrays of scalars are allowed for the query only; in the path, the existing message applies;
  - arrays of anything else → `query lists hold scalars (int, string, enum...)`.
  - Add a `tests/compile_fail/` case.
- OpenAPI: `{"in":"query","name":"tag","schema":{"type":"array","items":{...}},"style":"form","explode":true}`.

### [x] 5.4 Custom text types (UUID, dates, money...) — M

> **Done.** Protocol and helpers are in `vela.http.texttype` (shared with the Postgres driver). Text types may be `@system`: the framework calls them through `textFromString`/`textToString` (`@trusted`, added to the call-site list).

A compile-time-checked protocol, using D's usual `toString` convention:

```d
struct Uuid
{
    static bool fromString(scope const(char)[] text, out Uuid v);                  // path, query, JSON, database
    void toString(scope void delegate(scope const(char)[]) @safe sink) const;      // writes the text
    enum openApiFormat = "uuid";                                                   // optional
}
```

- Where it applies:
  - path and query parameters (extend `isScalar` with an `isTextType` check);
  - JSON, read and written as an escaped string;
  - OpenAPI: `{"type":"string","format":openApiFormat}`;
  - the Postgres driver: parameters through `toString`, cells through `fromString` (handy for `uuid` and `timestamptz`
    columns).
- When `fromString` returns false: error type `value_error`, message `invalid <TypeName>`. The type may override the
  message with `enum invalidMessage = "..."`.
- Update the `handlerError` message that lists the accepted parameter types.
- `docs/quickstart.md`: an example with a small `Uuid` and an ISO date. Apps may use `std.datetime`; the core may not.
- Tests in `tests/web/` and in `tests/db/pg_net.d` (a `uuid` column).

### [x] 5.5 Maps in JSON — S

- `V[string]`:
  - reading: a JSON object becomes an associative array; with duplicate keys, the last one wins;
  - writing: an object, in the associative array's order (unspecified; document it);
  - validation paths use the key;
  - OpenAPI: `{"type":"object","additionalProperties":<schema of V>}`.

### [x] 5.6 Query models `Query!T` — M (optional; do it when users ask)

> **Done.** Done together with 5.7 in `web/.../models.d`. A field is optional if `Optional`, a list, `@optional`, or its initializer differs from the type's default (so `int x = 0` counts as required: use `@optional`).

- `Query!Filters f` binds each field of the struct from the query string by name:
  - `@jsonKey` doubles as the external name (one attribute, documented as "external name");
  - defaults come from the struct's field initializers;
  - `Optional` fields are optional, and arrays are lists (5.3);
  - the validation attributes apply;
  - OpenAPI lists each field as its own query parameter.
- Follow the "new handler parameter kind" checklist.

### [x] 5.7 Form bodies `Form!T` — S/M (after 5.6)

- An `application/x-www-form-urlencoded` body bound into a struct, with the same binder as `Query!T`. Any other
  content type → 415 with a `detail` message.
- Buffered `multipart/form-data` (file fields on `Form!T`, still capped by `maxBodyBytes`) was added later. Unbuffered
  request bodies stay parked.

### [x] 5.8 Cookies — M

**Depends on** 1.1 (`addHeader`).

- Parameter kind `Cookie!"session"`: required like `Header!"X"`; `Optional!(Cookie!"x")` makes it optional; the value
  is a copied `string` (D2).
- `ctx.cookie("name")`: scans the `Cookie` headers without allocating. HTTP/2 may split cookies across several
  `cookie` fields, so read all of them.
- `ctx.setCookie(name, value, CookieOptions opts)`: builds a `Set-Cookie` through `addHeader`, supporting `Path`,
  `Domain`, `Max-Age`, `Expires` (use `vela.http.date`), `Secure`, `HttpOnly` and `SameSite`. Defaults: `HttpOnly` on,
  `SameSite=Lax`, `Secure` on (document how to turn it off for local development). An invalid cookie name (not a token)
  or value (not cookie-octets) throws, which is a programming error and so a 500.
- OpenAPI: `in: cookie`.

---

## Phase 6 — Docs and AGENTS.md

Every phase updates the docs it touches in the same commit. This phase is the final reorganization.

### [x] 6.1 A shorter README — S

> **Done.** About 100 lines; the old sections moved to `docs/`. The hello example is compiled by `tools/doc_examples.sh`.

At most about 120 lines:
- a one-paragraph pitch;
- the hello example, using `serve(&buildApp)`;
- one-line, factual feature bullets (drop the marketing tone of "Potential");
- status and known limits;
- requirements (the compiler versions from 0.1);
- links into `docs/`.

State the `@safe` guarantee precisely, as true after Phase 3: request data you keep is memory-safe; `string` and
`Header!"X"` already copy; a kept `const(char)[]` view may show newer bytes.

### [x] 6.2 Move details into `docs/` — S

> **Done.** `http2.md`, `tls.md` (separate from `deploy.md`, which stays the VPS walkthrough), `database.md`, `streaming.md`, `configuration.md`.

- `docs/http2.md`: the README's HTTP/2 section.
- TLS: merge into `docs/deploy.md`, or a new `docs/tls.md` (decide).
- `docs/database.md`: the Postgres driver.
- `docs/streaming.md`: Phase 4.
- `docs/configuration.md`: a `ServerConfig` reference.

`docs/quickstart.md` stays the tutorial.

### [x] 6.3 `AGENTS.md` — S

- Keep the rules. Cut the incident stories down to one-line rules. For example, "OpenSSL writes with write(2):
  SIGPIPE must stay ignored", without "a server that died on a client's reset taught this". The stories belong in
  commit messages.
- Update it for:
  - the per-worker App (D1);
  - the memory model (D2);
  - HTTP/2 and TLS frozen (D3), saying exactly what "frozen" allows;
  - the error policy (D4);
  - the `ResponseSink` engine contract;
  - the call-site list (`callBuild`, `callStream`);
  - `Optional` living in `vela:http`;
  - the `@trusted` accessor rule (1.10);
  - the exit-code-77 convention and CI.

### [x] 6.4 Make "executable documentation" true — S

> **Done.** `tools/doc_examples.sh` compiles every fenced `d` block whose first line is `// check` (README hello, quickstart sections 3 and 5, the deploy config); part of `check.sh`.

**Why (found while planning).** `AGENTS.md` says `docs/deploy.md` "is executable documentation: its config example must
compile", but no test compiles it (`grep -rn deploy.md tests tools` finds nothing).

**Change.** A small script, called from `check.sh`, that extracts the fenced ```` ```d ```` blocks marked with a
`// check` first line from `docs/*.md` and `README.md`, and compiles each with `-o-`. Mark the deploy config example
and the main quickstart examples.

---

## Phase 7 — Parked (do not start without the owner)

- New HTTP/2 or TLS features (D3), including WebSockets over HTTP/2 (RFC 8441). WebSockets over HTTP/1.1 were done in Phase 10.
- Streamed (unbuffered) request bodies. Buffered `multipart/form-data` is implemented (file fields on `Form!T`, still
  capped by `maxBodyBytes`).
- Range requests (206) and `sendfile` for static files (M4 performance work).
- DIP1000: revisit if D makes it the default. It would let `const(char)[]` views be checked by the compiler.
- Process-per-core workers: revisit if GC contention shows up (see the measurement in Phase 2).
- A separate concurrency limit for long-lived streams, instead of counting them in `maxInFlight`.
- Streaming responses in the HTTP client (proxying an upstream LLM stream).
- Everything already in `AGENTS.md`'s out-of-scope list: the rest of M4 (see Phase 8), kqueue (M5), io_uring (M6), IPv6
  listeners, OCSP stapling, response trailers and gRPC.

## Phase 8 — Performance (M4, first items)

Started on 2026-10-13 at the owner's request, after Phase 6. Only the HTTP/1.1 engine was touched; HTTP/2 and TLS stay frozen
(D3).

**Where the time goes (measured before any change).** One worker (LDC `-O3`, loopback, the client on other CPUs) served
~90-100k requests per second with or without pipelining, pinned at 100% of one core: ~10 µs of CPU per request. In process,
without sockets, the parser takes ~190 ns per head, `App.handle` plus `sendResponse` ~210 ns and the HTTP/1.1 head encoding
~57 ns. So the web layer is about 5% of the cost; the rest is the engine and the kernel (one `read`, one `send`, a share of
`epoll_wait`, two fiber switches). With 16 pipelined requests per connection it only reached ~120-130k: one `send` per
response.

### [x] 8.1 A throughput benchmark — S

> **Done.** `tests/net/bench.d` (a small wrk: keep-alive connections over threads, each with its own epoll loop, optional
> pipelining, latency percentiles), `tests/net/bench_serve.d` (`/plaintext`, `/json`, `/users/{id}` with a query parameter, a
> header and an app middleware) and `tools/bench.sh` (pins the server to CPU 0 with `taskset`). Not part of `check.sh`: the
> numbers are for before/after comparisons on one machine.

### [x] 8.2 Send the responses to pipelined requests together — M

> **Done.** `EpollLoop.coalesce`: when the next request is already in the buffer, the finished response is appended to
> `Conn.pending` (16 KiB at most) instead of being sent; `pendingQ` sends it at the end of the event batch at the latest, and
> every other write on the connection (`trySend`, `sendFully` from a streaming fiber, `sendRaw`) sends it first. An error that
> closes the connection waits for it (`closeAfterSend`, also used on EOF, when the client half-closes after its batch); an
> `Upgrade: h2c` behind held-back responses is served as HTTP/1.1. Cleartext only: OpenSSL wants a retried `SSL_write` to
> repeat the same bytes. `tools/bench.sh`, HEAD and this change back to back: 16 pipelined requests per connection
> **~124k -> ~444k requests per second** (3.6x); one request at a time ~91-93k -> ~95-97k (+3-5%, mostly 8.3). Tests:
> `testCoalescedPipelining` in `tests/net/epoll_net.d` (order, a suspended request behind a held-back response, a malformed
> request, half-close, `Expect: 100-continue`, a large response to a slow reader) and a stream behind a held-back response
> in `tests/net/stream_net.d` (it fails if `sendFully` does not send `pending` first).

### [x] 8.3 Parse each head once — S

> **Done.** Every HTTP/1.1 request was parsed three times: in `tryParse`, in `tryUpgrade` (h2c is on by default) and in
> `startRequest`, plus a fourth time for `Expect`. `parseHead` now remembers the result (`head`/`scratch`, keyed by connection,
> a per-connection head counter and the buffer address) and `parsedHead` hands it out; `startRequest` copies it into the
> fiber's own `Request`. About 0.4 µs per request: +3-5% without pipelining, within the noise of one run.

### [x] 8.4 Found while doing 8.2: chunked uploads above 64 KiB were quadratic — S

> **Done.** Above the largest buffer class (64 KiB) `fill` grew the read buffer by one byte when it was full, so a chunked body
> (whose size is not known up front) was copied once per read: the 700 KB upload in `testChunkedUploads` hung `check.sh` for
> minutes on HEAD too (5 runs out of 5 with `dmd -g`; it passed only when the timing was lucky). The buffer now doubles, capped at
> `headLen + maxBodyBytes + maxHeadBytes`; the test asserts the upload takes under 3 s.

### [ ] 8.5 Candidates, not started (measure with a profiler first)

- `EPOLLOUT` is always in the interest set (edge-triggered): count the events per request and try adding it only after a send
  hits `EAGAIN`.
- The read buffer goes back to the pool after every response and is taken again for the next request.
- `resume` reads the clock twice; `checkResponse` scans the headers once per vela-owned name (8 scans).
- SIMD search for the end of the head, GC tuning, `sendfile` for static files (the rest of M4).
- No profiler was available on the machine where 8.1-8.3 were done (`perf` missing): get one before going further, the
  estimates above are guesses.

## Phase 9 — Evidence for "HTTP/2 compatible"

Started on 2026-10-13 at the owner's request ("finish HTTP/2" -> what does it take to call vela HTTP/2 compatible). The server
already covered RFC 9113; what was missing was evidence, not features. HTTP/2 code untouched (D3 still holds).

### [x] 9.1 Run the real-browser test and h2spec locally — S

> **Done.** Chromium over TLS: every resource h2; h2spec 2.6.0: 146/146 over TLS, 145/146 in cleartext (3.5/2, expected).
> Fixed the browser section's cleanup trap (see "Not verified" above).

### [x] 9.2 Behind a real h2c reverse proxy — S

> **Done.** `tools/proxy_interop.sh` (new `check.sh` section, skips with 77 without Caddy; CI downloads Caddy 2.11.7, pinned by
> SHA-512): curl -> Caddy (HTTP/1.1) -> vela (h2c). Handlers see HTTP/2; upload, 4 MiB download, 404, 40 concurrent 300 ms
> requests in ~325 ms, SSE events arrive one at a time, a 20 MiB stream intact.

### [ ] 9.3 Candidates, not started

- `h2load` (nghttp2) as a third-party load client in `tools/h2_interop.sh` (not installed on the machine where 9.1-9.2 were done).
- Response trailers, needed before claiming gRPC (a new feature: needs D3 lifted).

## Phase 10 — WebSockets

Started on 2026-10-13 at the owner's request ("implement WebSockets"), on the `websockets` branch (a git worktree). Owner
choices: **a handler returns `WebSocket`** (like `Stream`, P6: parameters and middleware first, so a refusal is an ordinary
response), and the first version includes **a client** and **permessage-deflate**; no subprotocol API (the handler sets
`Sec-WebSocket-Protocol` on the context) and no Autobahn run (python `websockets` and Chromium instead). HTTP/2 stayed frozen
(D3) at first; RFC 8441 came later, in 10.7.
Reference: `docs/websocket.md`; rules for contributors: `AGENTS.md`, "WebSockets".

### [x] 10.1 Protocol, no I/O (`vela:http`) — M

> **Done.** `vela.http.sha1` (SHA-1, standard base64), `vela.http.websocket`: frame codec (8-byte unmasking, every length class),
> handshake check and accept key, permessage-deflate negotiation, and `WsConn`, the whole message layer (fragments, pings, the
> close handshake with a 1 s timeout, 1002/1007/1009, ping/idle timing, shutdown 1001, deflate through a `WsDeflate`
> interface) over an `UpgradedConn` (`vela.http.response`). `ResponseSink.upgrade` hands a connection over after a 101;
> `writeResponseHead` no longer writes `Content-Length` on 1xx; `statusText(101)`.

### [x] 10.2 Routes and dispatch (`vela:web`) — M

> **Done.** `app.ws!(path, fn)` / `@Ws` (a GET, not in OpenAPI), `WebSocket` (`maxMessageBytes`, `pingInterval`,
> `compression`), `runWebSocket` (426/400 refusals, the 101 through `checkResponse`, a new `WsConn` per connection, close 1000
> on return and 1011 on an exception, new user call site `callWebSocket`), three `compile_fail` cases, `TestClient.websocket`
> with a `WsScript`, `tests/web/websocket.d`. The layering holds: compression reaches the web layer as `Context.newDeflate`.

### [x] 10.3 Connection takeover in the engine — L

> **Done.** `Phase.upgraded` and `WsPort` in `epoll.d`: pending pipelined answers go out before the 101, early frames become
> input, the request buffer stays until close (the handler's params point into it), reads by the owner, writes from any fiber
> (whole frames, waiting for the drain like `waitH2Drain`), wake-ups decided in a fiber deferred to the end of the batch,
> `finishUpgraded` + `lingerClose`, graceful stop (1001), `sweepUpgraded` for stuck output, `LoopStats.webSockets(Total)`.
> `tests/net/ws_net.d` (11 tests, 8/8 repeated runs green) and a wss case in `tests/net/tls_net.d`.

### [x] 10.4 Compression and the client — M

> **Done.** `vela.engine.zlib` (dlopen `libz.so.1`, raw deflate with the 00 00 FF FF tail stripped, inflate with a size limit,
> context takeover; messages under 64 bytes uncompressed; an 8-bit window is never compressed). `vela.engine.wsclient`:
> `wsConnect` (`ws://`, `wss://`, deflate offer, getrandom masking keys) on `HttpClient`'s DNS/TCP/TLS (`openConn` and a few
> helpers became `package`); cooperative inside a fiber, blocking outside.

### [x] 10.5 Evidence — S

> **Done.** `tools/ws_interop.sh` (new `check.sh` section): python `websockets` 16 as a client against vela (with and without
> deflate, 3 MiB, ordering, ping, close codes) and as a server for `wsConnect`; CI installs `websockets>=13` with pip. The
> browser test opens a compressed `wss://` WebSocket from Chromium 156. `tests/alloc/ws_hot_path.d`: 0 GC bytes in 100k echoes,
> compressed or not. `tools/fuzz.sh ws` (3M runs clean) and `tests/fuzz/fuzz_ws.d` in `check.sh`. Memory: 1,000 open
> WebSockets peak at ~21 MB RSS (checked < 30 MB). Compile budget: 391 -> 398 ms on the same machine, with an `/echo` route
> added to `examples/hello`.

### [ ] 10.6 Candidates, not started

- The Autobahn|Testsuite (docker) as an optional interop section.
- A subprotocol helper (`WebSocket.protocols`), if setting the header by hand proves error-prone.
- A client send that finds the socket full while its owner waits stays queued until the owner's next wait; a per-connection
  writer wait (as on the server) would fix it if it matters.
- Fan-out across workers (a hub over `LISTEN/NOTIFY` in `vela-pg`, say).
- `wsConnect` over HTTP/2 (the client stays HTTP/1.1).

### [x] 10.7 WebSockets over HTTP/2 (RFC 8441) — L

Requested by the owner on 2026-10-14 ("implement the websocket via HTTP 2"), which lifts D3 for this item only. Branch
`websocket-h2`.

> **Done.** `vela:http`: `Request.connectProtocol`; `H2Session` announces `SETTINGS_ENABLE_CONNECT_PROTOCOL`
> (`H2Config.enableConnectProtocol`), accepts `:protocol`, hands an extended CONNECT out at its HEADERS as a GET
> (`H2Stream.tunnel`), keeps its DATA without a body limit and credits the stream window only as the engine consumes
> (`popInput`, `tunnelInput`, `tunnelConsume`, `tunnelEnded`); ending our side half-closes the stream (reset after 1 s in
> `tick`); other `:protocol` values get 501. `ByteBuffer.dropFront`. `vela:web`: `checkUpgradeRequest` for HTTP/2,
> `runWebSocket` answers 200 without an accept key, `dispatch` refuses an extended CONNECT on a non-WebSocket route with 400,
> `TestClient.http2`. `vela:engine`: `H2Tunnel` (`upgradeStream`, `tunnelFill/Write/Break`, `finishTunnel`), graceful stop
> (1001), `ServerConfig.http2WebSockets`.
> Evidence: 10 session tests, `tests/web/websocket.d` (h2 mode), `tests/net/ws_h2_net.d` (9 socket tests, 3/3 runs green),
> `tests/net/ws_h2_interop.py` (python-h2 + the `websockets` frame codec and permessage-deflate, h2c and TLS) in
> `tools/ws_interop.sh`, Chromium 156 opens the page's `wss` WebSocket as a stream of its h2 connection (and on HTTP/1.1 with
> `http2WebSockets = false`), the fuzz invariants drive tunnels (`fuzz_h2.d` seeds also start libFuzzer's corpus: 12.6M runs
> clean), 0 GC bytes in 100k echoes over a session tunnel, 1,000 open WebSockets over 10 h2 connections peak at ~19 MB RSS
> (checked < 30 MB), compile budget 398 -> 401 ms. Not run here: h2spec (not installed on this machine).

## Phase 11 — Features for real applications

Started on 2026-10-14, branch `real-app-features`. A production app (Visto) is moving its backend from Python/Sanic to
vela and must keep its HTTP contract exactly. Checking what it uses against vela gave the items below. Each is a general
feature with docs and tests, and every default stays what it was. Out of scope (stop and ask if an item seems to need
one): per-route body limits, unbuffered request bodies, streaming responses in the HTTP client, per-route request
timeouts, any HTTP/2 or TLS feature (D3).

### Decision log

| # | Item | Decision | Rejected | Why |
|---|------|----------|----------|-----|
| F1 | 11.1 | `app.onValidationError(h)` with `h(Context, ValidationErrors)`; the response starts as an empty 422. | Throwing a `ValidationError` exception to `onError`; passing `ref FieldErrors`. | Exceptions would cost the hot error path an allocation and mix framing errors with field errors. A small view struct (`items`, `dropped`) is easy to take by value, `@safe`, and points into the Context, so nothing is copied. |
| F2 | 11.1 | `FieldError` gains `source` (`ErrorSource`: path, query, header, cookie, jsonBody, form), `path()` and `dotted()`. `location`/`locJson` unchanged. | Storing the path as segments instead of `locJson`. | The default 422 stays byte-identical and the hot path stores the same as before; `path()` parses `locJson` only when a handler asks. `form` tells a `Form!T` body from a JSON one, which `loc` (`"body"` for both) cannot. |
| F3 | 11.1 | A group can override the app's handler; the nearest group wins; resolved once per route at `freeze`, stored in `Context.onValidation` when the route matches (one pointer store). Controllers from `mount` use the app's. | App-only handler. | APIs often mount a public `/api` and an internal part with different contracts; the cost is one store per request, and the resolution happens once. |
| F4 | 11.1 | 415 (wrong form content type) and 400 (malformed multipart) stay `HttpError`s for `onError`. | Turning them into validation errors. | They are about the framing, not a field; routing them through validation would change which hook sees them for existing apps. Documented, with the statuses unchanged. |
| F5 | 11.1 | OpenAPI: the default documents the 422 as before; `onValidationError!Body(status, h, description)` documents `status` with `Body`'s schema; a handler without a declaration documents a generic `4XX` without a schema. | Keeping the 422 entry; an OpenAPI-only attribute per route. | A 422 that the app never sends would lie. `4XX` says only what is known. Other statuses the handler picks (a 404 for a path) go on routes with `@responds`. |
| F6 | 11.1 | The user handler is called through a new `callUser` overload (the existing call site name); `dispatch` reaches it through `Context.onValidation`, a framework `@safe` delegate. | A new call-site function in `handler_traits.d`. | Keeps the list of places that call user code the same. |
| F8 | 11.2 | The tri-state type is `PatchField!T` (owner's pick), in `vela:http` next to `Optional`. | `Patch!T` (clashes with the `@Patch` route UDA under `import vela;`); `Nullable!T` (clashes with `std.typecons`); `Tristate!T`. | Names the use (PATCH bodies) and clashes with nothing. In `vela:http` so the database driver can share it later. |
| F9 | 11.2 | `writeJson` omits an absent `PatchField` from its object; `null` for a null one; outside an object absent is `null`. | Writing `null` for absent everywhere. | Round-trips the three states through a struct; an array has no way to leave an element out. |
| F10 | 11.2 | JSON bodies only: `PatchField` in `Form!T`, `Query!T` or as a handler parameter is a one-line compile error pointing to `Optional!T`. | Mapping an empty form value to `null`. | Forms and query strings have no `null`; guessing from an empty string would make `""` impossible to send. |
| F11 | 11.3 | `JsonValue` is a plain struct with one field per kind (no union); objects are a member array in input order; a repeated key keeps its first position and last value, with a hash index past 8 members. | A tagged union (pointer overlap is `@system`); an AA for objects (loses order); linear duplicate search (quadratic on hostile input). | `@safe` without `@trusted`; order is part of the requirement; the index keeps a 1 MiB body of repeated keys linear. |
| F12 | 11.3 | Strict JSON number grammar for `JsonValue`; integer when it fits `long`, floating otherwise; a number that overflows `double` or is longer than 63 characters is an error; an integral floating number is written with `.0`. | Accepting what `strtod` accepts; writing `1.0` as `1`. | Untrusted input should not get more lenient than JSON; `.0` keeps the kind across a round trip, which the fuzz invariant checks. |
| F13 | 11.3 | Depth limit 64 (the same as `skipValue`), counted inside the `JsonValue`; `parseJson` also has `maxBytes` (16 MiB). Limit errors are `json_invalid` with their own message (`JsonReader.fail`). | One shared depth counter for typed and dynamic decoding. | Typed nesting is bounded by the type; only `JsonValue` recursion depends on the input. |
| F14 | 11.3 | Public `parseJson`, `fromJson!T`, `toJson`, `writeJson` for JSON outside a request. | Only `parseJson`. | Reading an upstream response into a DTO is the common case and reuses the body decoder's rules and errors. |
| F15 | 11.3 | Fuzzing: `tests/fuzz/json_invariants.d` (round trip, depth, a typed decode), `fuzz_json.d` in `check.sh`, `tools/fuzz.sh … json`. `fuzz.sh` now sets `detect_stack_use_after_return=0` for every target. | Leaving ASan's default. | ASan's fake stack hides locals from the conservative GC: after ~700k runs a collection freed live objects and the round trip "changed" a value. With it off: 6M runs clean. |
| F7 | 11.1 | `Context.json(value, status = 200)` added, for error and validation handlers. `writeValidationErrors` is renamed `writeDefaultValidationErrors` (public; the old name stays as an alias). | Asking handlers to build JSON by hand. | A custom error body is almost always a small struct. |

### [x] 11.1 Custom validation error responses: `onValidationError` — M

> **Done.** `vela.web.application`: `ValidationErrorHandler`, `App/Group.onValidationError(h)` and `!Body(status, h,
> description)` (one-line compile errors for a wrong handler type and a non-struct body; a bad status throws `RouteError`),
> resolution at `freeze`; `vela.web.dto`: `ErrorSource`, `LocPart`, `FieldError.source/path/dotted`, `ValidationErrors`
> (`has`), `FieldErrors.view`; `vela.web.openapi`: `ValidationDoc`, `Components.validation`, `OpRecord.validation`;
> `Context.json`. Tests: `tests/web/validation_handler.d` (every failure kind, path -> 404, framing errors unchanged, dropped
> count, default byte-identical, a handler that writes only a body / falls back / throws, nested group override, a mounted
> controller with a `@system` function, the three OpenAPI cases, a bad status, registration after freeze), `dto.d`
> unittest, `tests/compile_fail/validation_handler_signature.d`, `validation_handler_body.d`. Docs: `validation.md` (a
> `// check` example), `static-files-and-openapi.md`, the index; `AGENTS.md` call sites.

### [x] 11.2 Tri-state JSON fields: `PatchField!T` — M

> **Done.** `vela.http.patchfield`: `PatchField!T` (`isAbsent`, `isNull`, `hasValue`, `isPresent`, `value`, `valueOr`,
> `null_`, `absent`), `isPatchField`; re-exported by `vela.web.params`. `json.d`: read (`null` -> null, a value -> decoded
> with the usual errors, never `missing`), written (absent left out of its object). `validateField` checks the value only.
> OpenAPI: `nullable`, not required, constraints on the value. `modelError` and `handlerError` reject it outside a JSON body.
> Tests: `json.d` unittest (three states, nested, arrays of structs, validation, writing), `tests/web/patchfield.d` (a PATCH
> route, 422 `loc`s, a response that omits absent fields, OpenAPI), `tests/compile_fail/form_patchfield.d`,
> `param_patchfield.d`. Docs: `requests.md` (a `// check` example), `validation.md`, the index.

### [x] 11.3 Dynamic JSON value: `JsonValue` — M

> **Done.** `vela.web.jsonvalue`: `JsonValue` (kinds, accessors, `get`, `opIndex`, building, `opEquals`, `toString`),
> `JsonMember`, `JsonType`, `JsonError`, `JsonLimits`, `parseJson` (throwing and not), `fromJson!T`, `toJson`,
> `readJsonValue`/`writeJsonValue`; `JsonReader.fail`/`errorText`. Wired into `readJson`/`writeJson` (body, DTO field, maps,
> arrays, return value) and OpenAPI (`{}`). Tests: module unittests (kinds, order, repeated keys past the index, errors,
> numbers, depth, size, UTF-8, building, `fromJson`), `tests/web/json_value.d` (routes, 422s with `loc`, OpenAPI),
> `fuzz_json.d` (300k inputs in `check.sh`), `tools/fuzz.sh 400 json`: 5.98M runs clean. Docs: `requests.md` and
> `http-client.md` (`// check` examples), the index.

### [ ] 11.4 `vela:crypto` — L

### [ ] 11.5 Array parameters in `vela-pg` — S

### [ ] 11.6 Nested row mapping in `rowsAs!T` — S/M

### [ ] 11.7 Savepoints in `vela-pg` — S

### [ ] 11.8 Structured logger `vela.log` — M

### [ ] 11.9 `TestClient` ergonomics — S/M

### [ ] 11.10 `httpClient` additions — S

## Open owner decisions (not blocking)

- **The final name.** "vela" collides with KubeVela and go-vela; also check code.dlang.org. Rename before the first
  public release. The rename is mechanical: package names, `vela.*` module names, the `vela:` message prefix, the docs.
- **When to unfreeze HTTP/2 and TLS** (D3).
- **Whether and when to publish on code.dlang.org** (after Phase 4 or Phase 5?).

---

## Appendix A — Evidence gathered during the review

These probes were run with LDC 1.40.1 against `vela:web` only (the full package does not build on that compiler; see
0.1). They are small enough to re-run after each fix.

**Wrong JSON for `Maybe`, CRLF in headers, lost array index** (items 1.3, 1.1, 1.4):

```d
import vela.web;
import vela.db.pg : Maybe;

struct Row { int id; Maybe!string email; }
struct Item { string name; @minLength(3) string code; }
struct Order { Item[] items; }

Row row() => Row(1, Maybe!string("a@b.c"));
Response redir(string to) => Response.redirect(to);
void order(JsonBody!Order o) {}

void main()
{
    import std.stdio;
    auto app = new App;
    app.get!("/row", row);
    app.get!("/redir", redir);
    app.post!("/order", order);
    auto c = TestClient(app);
    writeln(c.get("/row").body);
    writeln([c.get("/redir?to=/x%0d%0aSet-Cookie:%20pwned=1").header("Location")]);
    writeln(c.post("/order", `{"items":[{"name":"a","code":"abcd"},{"name":"b","code":"x"}]}`).body);
}
```

Output at `365cae1`:

```
{"id":1,"email":{"value":"a@b.c","has":true}}
["/x\r\nSet-Cookie: pwned=1"]
{"detail":[{"loc":["body","items.code"],"msg":"below the minimum length of 3"}]}
```

Build command, run from the repository root:
`ldmd2 -i -Ihttp/source -Iweb/source -Iengine/source -Idrivers/pg/source probe.d`.

**Bytes instead of characters, and a slice escaping `@safe` code** (items 1.4 and Phase 3):

```d
@safe:
import vela.web;
struct Item { @minLength(3) string code; }
const(char)[] leaked;                                                // thread-local
string keep(Header!"X-Tok" t) { leaked = t; return "ok"; }           // compiles in @safe code
void item(JsonBody!Item o) {}
// POST {"code":"çã"} (2 characters, 4 bytes) -> 204: @minLength(3) passed
```

**DIP1000 experiment** (why D2 was chosen over it):
- With `-preview=dip1000`, a handler `string bad(scope Header!"X" h) { leaked = h; ... }` fails with a clear message:
  ``scope variable `h` assigned to global variable `leaked` ``.
- A harmless handler **without** `scope` (`string clean(Header!"X" h) => h.idup;`) also fails, with an error pointing
  inside the dispatch template plus a template-instantiation line. So `scope` would be mandatory on every such
  parameter.
- Without the flag, everything compiles, including the bad case.
- vela itself does not compile with the flag (`web/.../testing.d:39–42` fail first).

**GC cost of copying a 40-byte header** (LDC 1.40, `-O3 -release`, 16 cores):

| | Cost |
|---|------|
| 1 thread | ~55 ns per copy |
| 4 threads at once | ~158 ns per copy (wall time / total copies): 4× the work took ~11× longer |

The longest collection pause measured was ~4 ms (D's collector stops every thread while it runs). Conclusion: copying a header costs well under 1% of a realistic
request, but GC allocation does not scale across threads in one process, so the framework's hot path must stay
GC-free.

**Build failures on DMD 2.109.1 / LDC 1.40.1:** see 0.1.

## Appendix B — Definition of done (every item)

- [ ] `tools/check.sh` is green on DMD and LDC (and with `VELA_STRICT=1` in CI once 0.5 exists).
- [ ] New tests cover the change; every new signature rule has a `tests/compile_fail/` case with a one-line message.
- [ ] The hot path is still GC-free (`tests/alloc`), and the memory tests are within their limits.
- [ ] HTTP/2 changes: `tools/h2_interop.sh` plus `tools/fuzz.sh 300 h2`. Parser changes: corpus files plus
      `tools/fuzz.sh 300 parse`.
- [ ] Docs are updated in the same commit (README, quickstart, `AGENTS.md`, deploy guide, as relevant).
- [ ] English everywhere; `vela:` prefixes; `@safe`, with every new `@trusted` commented.
- [ ] The item's checkbox in `PLAN.md` is ticked.
