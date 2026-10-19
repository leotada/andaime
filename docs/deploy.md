# Deploying on a VPS (HTTPS, no proxy in front)

This guide takes an application from `dub build` to serving browsers over HTTPS and HTTP/2 on
ports 443 and 80, with a Let's Encrypt certificate that renews without restarts. It assumes a
Linux server (Debian/Ubuntu commands), a domain `example.com` pointing at it, and an application
user `andaime`. Everything here is what `tools/check.sh` exercises, except the Let's Encrypt part,
which needs a real domain.

## 1. Build

```sh
dub build -b release --compiler=ldc2      # LDC gives the fastest binary
sudo install -D -m 0755 ./myapp /opt/myapp/myapp
sudo apt install libssl3                  # OpenSSL 3, loaded at run time
```

The native libraries (OpenSSL, zlib, libpq) are loaded with `dlopen` the first time something needs them, so a
container image without `libssl3` builds fine and fails on the first HTTPS call. To fail at build time instead, give the
binary a `--check-runtime` switch that asks the library and run it in the image build (`RUN ./myapp --check-runtime`).
`tlsAvailable`, `zlibAvailable` (and `pgAvailable` from `andaime.db`) say whether a library loaded; `tlsLoadError`,
`zlibLoadError` and `pgLoadError` return the reason (an `Optional!string` with the library name and the dynamic loader's
message). Asking prints nothing and changes no signal handling.

```d
// check
import andaime;
import core.stdc.stdio : fprintf, stderr;

int main(string[] args)
{
    if (args.length > 1 && args[1] == "--check-runtime")
    {
        int missing;
        foreach (why; [tlsLoadError, zlibLoadError])
            if (why.has)
            {
                fprintf(stderr, "%.*s\n", cast(int) why.get.length, why.get.ptr);
                missing++;
            }
        return missing ? 1 : 0;
    }
    // ... build the app and call serve ...
    return 0;
}
```

## 2. The server configuration

```d
// check
import andaime;

string home() => "hello";

// Every worker calls this once, on its own thread, and serves its own App.
App buildApp()
{
    auto app = new App;
    app.get!("/", home);   // ... your routes ...

    // HSTS: browsers that saw it once go straight to HTTPS for a year
    app.use((Context ctx, Next next) {
        ctx.setHeader("Strict-Transport-Security", "max-age=31536000");
        next();
    });
    return app;
}

void main()
{
    ServerConfig cfg;
    cfg.port = 443;
    cfg.tls.certFile = "/etc/andaime/tls/cert.pem";   // copied there by certbot's deploy hook (below)
    cfg.tls.keyFile = "/etc/andaime/tls/key.pem";
    cfg.tls.redirectPort = 80;                      // ACME challenges + 308 to https
    cfg.tls.acmeWebroot = "/var/www/acme";
    serve(&buildApp, cfg);
}
```

What the two ports do:

- **443**: TLS 1.2/1.3; ALPN gives browsers HTTP/2 and everything else HTTP/1.1.
- **80**: never reaches your handlers. `GET /.well-known/acme-challenge/<token>` is answered from
  `/var/www/acme/.well-known/acme-challenge/<token>`; any other request gets
  `308 Permanent Redirect` to the same host and path on `https://`.

Without `tls.certFile`, the same binary serves cleartext HTTP/1.1 and h2c, for running behind a proxy.

## 3. Certificates

The server will not start without its certificate, and port 80 is the server's. So the first
certificate comes from certbot's own web server, before andaime runs; renewals then go through
andaime's port 80.

```sh
sudo apt install certbot
sudo mkdir -p /var/www/acme /etc/andaime/tls

# first certificate: certbot listens on port 80 itself (andaime is not running yet)
sudo certbot certonly --standalone -d example.com
```

A deploy hook copies the files where the application user can read them. It writes temporary
files and renames them, so andaime never reads a half-written key:

```sh
sudo tee /etc/letsencrypt/renewal-hooks/deploy/andaime.sh > /dev/null <<'EOF'
#!/bin/sh
set -e
d=/etc/andaime/tls
install -m 0640 -o root -g andaime "$RENEWED_LINEAGE/privkey.pem" "$d/key.pem.new"
install -m 0644 -o root -g andaime "$RENEWED_LINEAGE/fullchain.pem" "$d/cert.pem.new"
mv "$d/key.pem.new" "$d/key.pem"
mv "$d/cert.pem.new" "$d/cert.pem"
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/andaime.sh
sudo RENEWED_LINEAGE=/etc/letsencrypt/live/example.com /etc/letsencrypt/renewal-hooks/deploy/andaime.sh
```

Start andaime (section 4), then switch renewals to the webroot it serves (certbot 2.3 or newer; this
also runs a test renewal against your server):

```sh
sudo certbot reconfigure --cert-name example.com --webroot -w /var/www/acme
sudo certbot renew --dry-run
```

From now on certbot's timer renews the certificate, the hook replaces the two files, and every
worker notices within `tls.reloadCheckMs` (10 s) and loads them. Open connections keep the old
certificate; new ones get the new one. If a file fails to load, andaime logs
`andaime: TLS: ... (keeping the previous certificate)` and keeps serving.

## 4. systemd

```ini
# /etc/systemd/system/myapp.service
[Unit]
Description=myapp
After=network-online.target
Wants=network-online.target

[Service]
User=andaime
Group=andaime
WorkingDirectory=/opt/myapp
ExecStart=/opt/myapp/myapp
# ports 80 and 443 without running as root
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
# SIGTERM is a graceful stop: in-flight requests finish (shutdownGraceMs, 10 s), HTTP/2 gets GOAWAY
KillSignal=SIGTERM
TimeoutStopSec=15
Restart=on-failure
LimitNOFILE=65536
# hardening: a read-only system; add ReadWritePaths= for anything your application writes
ProtectSystem=strict
ReadOnlyPaths=/etc/andaime /var/www/acme
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```sh
sudo useradd --system --no-create-home andaime
sudo systemctl daemon-reload && sudo systemctl enable --now myapp
sudo ufw allow 80,443/tcp
curl -I http://example.com/          # 308 to https://example.com/
curl -I https://example.com/         # HTTP/2 200
```

Without systemd: `sudo setcap cap_net_bind_service=+ep /opt/myapp/myapp` lets the binary bind
ports below 1024 as an ordinary user (redo it after each new build).

## 5. Logs and limits

- `andaime: TLS handshake failed from <ip>: <reason>` and `andaime: HTTP/2 connection error from <ip>: <code>`
  appear at most once per second per worker, with a count of the lines skipped. Clients that just
  disconnect mid-handshake (port scanners, health checks) are counted (`LoopStats.tlsFailures`), not
  logged. `cfg.logConnectionErrors = false` silences them.
- Memory: each TLS connection costs tens of KiB in OpenSSL on top of the request; 1,000 requests in
  flight over HTTPS peak at ~44 MB with OpenSSL 3.0 and 56-71 MB with OpenSSL 3.5. On a 512 MB VPS the defaults are fine; `maxInFlight` (1,024 per
  worker) and `maxConnections` (10,000 per worker) are the knobs.
- One worker per core by default (`cfg.workers`). Each worker loads its own copy of the certificate.
- An unexpected error in a handler answers 500 and is logged with its stack trace (at most 5 traces per second per worker, then a
  count). Symbol names in the trace need debug info: build with `-g` (DUB's `release-debug` build type). An `Error` such as a
  `RangeError` also retires that fiber (`LoopStats.fibersPoisoned`).
- A handler that overflows its fiber stack kills the process with SIGSEGV; the last line on stderr names the request and the
  setting to raise (`ServerConfig.fiberStackBytes`, 256 KiB by default).
- Memory returns to the OS after a burst (a quiet second, then a collection); if RSS looks high right after a traffic spike, wait a
  couple of seconds before judging.
- Background jobs on Postgres: completed rows are purged after a day and discarded ones after 14 days
  (`PgJobStore.completedRetention`, `discardedRetention`). A job whose payload carries a code or a token should be
  `@Job("...") @DropOnSuccess`, so it leaves nothing in `andaime_jobs` once sent (see
  [Background jobs](jobs-and-cron.md#retention)).

## Behind a reverse proxy

The TCP peer is the proxy. List it in `cfg.trustedProxies = ["127.0.0.1", "10.0.0.0/8"]` and handlers get the real client from
`ClientIp` / `ctx.clientIp()` (the first address in `X-Forwarded-For`, from the right, that is not a trusted proxy). The header
from any other peer is ignored, because anyone can send it. `accessLog()` prints `ip=`.

Server-Sent Events and other streamed responses need the proxy not to buffer them. andaime already sends `X-Accel-Buffering: no`
(nginx honors it per response) and `Cache-Control: no-cache` on an `EventStream`. Other proxies have their own switch for
response buffering or flushing (Caddy's `reverse_proxy` has `flush_interval -1`); check yours. Idle SSE connections should send
a heartbeat (`w.comment()`) more often than the proxy's idle timeout.

## Known limits

- **IPv4 only**: the listeners bind IPv4 addresses (`cfg.host`, default `0.0.0.0`). An AAAA record
  pointing at the server will not reach andaime yet; publish only an A record.
- No OCSP stapling and no client certificates (mutual TLS).
- The redirect port is for `redirectPort` only; serving the application itself in cleartext next to
  HTTPS is not supported (run a second process if you need it).
