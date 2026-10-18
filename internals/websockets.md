# WebSockets

Read before touching `http/.../websocket.d`, `web/.../websocket.d`, `wsclient.d` or `Phase.upgraded` in `epoll.d`.

- Layers: `andaime.http.websocket` has the codec, the handshake and `WsConn` (the whole message layer: fragments, pings, close
  handshake, limits, ping/idle timing, deflate hooks) and does I/O only through `UpgradedConn` (`andaime.http.response`). The engine
  implements `UpgradedConn` on a server connection (`WsPort` in `epoll.d`), `wsclient.d` on a client one, `TestClient` in memory.
  Protocol rules belong in `WsConn`, where the unittests, `tests/web/websocket.d` and the fuzzers reach them without sockets.
- The web layer never imports the engine: compression reaches it as `Context.newDeflate` (a `WsDeflateFactory`), set by
  `server.d` to `andaime.engine.zlib`.
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
