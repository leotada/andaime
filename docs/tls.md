# HTTPS

```d
ServerConfig cfg;
cfg.port = 443;
cfg.tls.certFile = "/etc/letsencrypt/live/example.com/fullchain.pem";
cfg.tls.keyFile = "/etc/letsencrypt/live/example.com/privkey.pem";
serve(&buildApp, cfg);   // browsers get HTTP/2; clients without ALPN or without h2 get HTTP/1.1
```

[deploy.md](deploy.md) walks through a VPS deployment (Let's Encrypt, systemd, ports 80/443 as an unprivileged user, HSTS, logs).

- With a certificate the listener speaks TLS only, and ALPN chooses HTTP/2 or HTTP/1.1. `cfg.tls.redirectPort = 80` adds a
  cleartext listener that answers ACME HTTP-01 challenges from `cfg.tls.acmeWebroot` (certbot `--webroot`) and sends every other
  request a 308 to the same host and path over HTTPS; it never reaches your handlers.
- TLS 1.2 and 1.3; for TLS 1.2 only ECDHE with AEAD ciphers (Mozilla's "intermediate" list, which also meets HTTP/2's
  requirements); no compression, no renegotiation. Session resumption uses stateless tickets, with keys shared by all workers
  and kept for the life of the process.
- Certificate renewal needs no restart: each worker checks both files every `tls.reloadCheckMs` (10 s) and reloads them when
  they change (certbot's symlink swaps included). New connections get the new certificate; open ones keep theirs. A file that
  fails to load is logged and the previous certificate stays.
- The handshake must finish within `headerTimeoutMs`, and an HTTP/2 client must acknowledge our SETTINGS within the same time.
  Prior knowledge and `Upgrade: h2c` are cleartext features: over TLS, HTTP/2 is only chosen through ALPN.
- Failed handshakes and HTTP/2 connection errors are logged with the client's address, at most one line per second per worker
  (`cfg.logConnectionErrors`); clients that merely disconnect mid-handshake are only counted.
- OpenSSL 3 is loaded at run time, as for the HTTP client (`libssl3`); without a certificate it is never loaded. Loading it sets
  SIGPIPE to ignored (unless the application installed a handler), because OpenSSL writes to sockets with write(2) and a client
  that resets the connection would otherwise kill the process.
- Memory: OpenSSL keeps tens of KiB per connection, on top of the request. 1,000 in-flight HTTPS requests on 1,000 connections
  peak at ~44 MB (HTTP/1.1) and ~38 MB (h2) with OpenSSL 3.0, and at 56-71 MB with OpenSSL 3.5, against ~25 MB in cleartext; the
  in-flight ceiling (`maxInFlight`) is what bounds it on a small VPS.
- Tested with a real browser: Chromium loads a page with 26 assets and API calls over h2, follows the redirect from the
  cleartext port, and falls back to HTTP/1.1 when HTTP/2 is disabled (`tests/net/browser_test.py`).
- Handlers see the client's address (`ClientIp`, `ctx.clientIp()`); behind a proxy set `ServerConfig.trustedProxies`. Listeners
  are IPv4 only for now.
