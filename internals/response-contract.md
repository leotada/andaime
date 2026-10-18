# The response contract

Read before touching `engine/`, `server.d` or `web/.../stream.d`.

- The engine calls `RequestCallback(ref Request, ResponseSink)` (`andaime.http.response`): `sink.start(ResponseHead)`, any number of
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
  (`BufferedSink`, the devserver, an HTTP/2 stream that is not an extended CONNECT), before anything was sent. See
  [websockets.md](websockets.md).
