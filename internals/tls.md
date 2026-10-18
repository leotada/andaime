# TLS

Read before touching `tlsserver.d` or the TLS parts of `epoll.d`. Frozen like HTTP/2 (D3): see [http2.md](http2.md).

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
