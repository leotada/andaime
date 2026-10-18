# HTTP/2

Read before touching `http/.../h2.d` or the h2 part of `epoll.d`.

**Frozen (D3).** No new HTTP/2 or TLS features until the owner says so. Allowed: bug fixes, and the changes other plan items
require (response sink, memory model). The owner lifted it once, for WebSockets over HTTP/2 (RFC 8441, `PLAN.md` 10.7).
Everything below still applies to those.

- Protocol logic lives in `H2Session` (`andaime.http.h2`), which does no I/O: the engine feeds it bytes (`receive`), runs what
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
