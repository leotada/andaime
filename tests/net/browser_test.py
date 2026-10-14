#!/usr/bin/env python3
"""Real browser against vela (Chromium through Playwright): loads a page over HTTPS with 26 static
assets and three API calls, checks the protocol Chromium negotiated for every resource (h2 by
default, http/1.1 with HTTP/2 disabled), follows the redirect from the cleartext port, checks a
2 MiB script arrives intact, and opens a wss:// WebSocket (echo, 140 KB message, permessage-deflate). Usage: browser_test.py <server binary>. Prints "skip: <reason>" and exits 77
when Playwright or Chromium is not available."""
import os
import socket
import subprocess
import sys
import tempfile
import time


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def fail(msg):
    print("FAILED: browser:", msg)
    sys.exit(1)


try:
    from playwright.sync_api import sync_playwright
except ImportError:
    print("skip: python playwright not installed", file=sys.stderr)
    sys.exit(77)

work = tempfile.mkdtemp(prefix="vela_browser_")
pub = os.path.join(work, "public")
os.makedirs(pub)
with open(os.path.join(pub, "style.css"), "w") as f:
    f.write("body { font-family: sans-serif } img { width: 16px }\n")
for i in range(24):
    with open(os.path.join(pub, "img%d.svg" % i), "w") as f:
        f.write('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16">'
                '<rect width="16" height="16" fill="#%06x"/></svg>' % (i * 0x0a0b0c))
filler = "".join("/*%07d*/" % i for i in range((2 << 20) // 11))
with open(os.path.join(pub, "big.js"), "w") as f:
    f.write(filler + "\nwindow.bigOk = true;\n")
cert, key = os.path.join(work, "cert.pem"), os.path.join(work, "key.pem")
r = subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                    "-keyout", key, "-out", cert, "-days", "2", "-subj", "/CN=localhost",
                    "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"], capture_output=True)
if r.returncode != 0:
    print("skip: the openssl command failed", file=sys.stderr)
    sys.exit(77)

port, rport = free_port(), free_port()
srv = subprocess.Popen([sys.argv[1], str(port), str(rport), cert, key, pub],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
try:
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            break
        except OSError:
            time.sleep(0.05)

    def load(browser, url):
        ctx = browser.new_context(ignore_https_errors=True)  # self-signed certificate
        page = ctx.new_page()
        failed = []
        page.on("requestfailed", lambda req: failed.append(req.url))
        resp = page.goto(url, wait_until="load")
        page.wait_for_function("window.result !== undefined", timeout=15000)
        result = page.evaluate("window.result")
        protos = page.evaluate("""() => [performance.getEntriesByType('navigation')[0].nextHopProtocol,
            ...performance.getEntriesByType('resource').map(e => e.nextHopProtocol)]""")
        final = page.url
        ctx.close()
        return resp, result, protos, failed, final

    def check_result(result, failed, proto, label, ws_proto=None):
        if failed:
            fail("%s: failed requests %s" % (label, failed))
        if "error" in result:
            fail("%s: page script error %s" % (label, result["error"]))
        if result["item"] != {"id": 7, "name": "item 7"}:
            fail("%s: GET /api/items/7 -> %s" % (label, result["item"]))
        if result["status"] != 201 or result["made"] != {"id": 99, "name": "from the browser"}:
            fail("%s: POST -> %s %s" % (label, result["status"], result["made"]))
        if result["proto"] != proto:
            fail("%s: the handler saw %s" % (label, result["proto"]))
        if not result["bigOk"]:
            fail("%s: the 2 MiB script did not run" % label)
        ws = result["ws"]
        if ws["echo"] != "hello from the browser" or not ws["bigOk"] or ws["code"] != 1000:
            fail("%s: WebSocket -> %s" % (label, ws))
        if not ws["extensions"].startswith("permessage-deflate"):
            fail("%s: WebSocket not compressed (extensions %r)" % (label, ws["extensions"]))
        if ws["proto"] != (ws_proto or proto):
            fail("%s: the WebSocket ran over %s, expected %s" % (label, ws["proto"], ws_proto or proto))

    with sync_playwright() as p:
        try:
            browser = p.chromium.launch()
        except Exception as e:  # no browser binary
            print("skip: Chromium could not start (%s)" % str(e).splitlines()[0], file=sys.stderr)
            sys.exit(77)
        version = browser.version

        resp, result, protos, failed, _ = load(browser, "https://localhost:%d/" % port)
        if resp.status != 200:
            fail("page status %d" % resp.status)
        check_result(result, failed, "h2", "HTTP/2")
        if len(protos) < 29 or any(x != "h2" for x in protos):
            fail("expected h2 for every resource, got %s" % protos)
        print("ok  Chromium %s over HTTPS: page, 26 assets (2 MiB script) and 3 API calls, all h2; a wss WebSocket "
              "with permessage-deflate as a stream of the same connection (RFC 8441)" % version)

        _, result, protos, failed, final = load(browser, "http://localhost:%d/" % rport)
        if final != "https://localhost:%d/" % port:
            fail("the redirect from the cleartext port ended at %s" % final)
        check_result(result, failed, "h2", "redirected")
        print("ok  Chromium followed http://localhost:%d/ -> %s" % (rport, final))
        browser.close()

        browser = p.chromium.launch(args=["--disable-http2"])
        _, result, protos, failed, _ = load(browser, "https://localhost:%d/" % port)
        check_result(result, failed, "http/1.1", "HTTP/1.1")
        if any(x != "http/1.1" for x in protos):
            fail("with HTTP/2 disabled, expected http/1.1, got %s" % set(protos))
        print("ok  Chromium with HTTP/2 disabled: the same page over HTTP/1.1 (ALPN fallback)")
        browser.close()

        # the server without WebSockets over HTTP/2: the page stays on h2, the WebSocket gets its own HTTP/1.1 connection
        srv.terminate()
        srv.communicate(timeout=10)
        srv = subprocess.Popen([sys.argv[1], str(port), str(rport), cert, key, pub, "no-h2-websockets"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.05)
        browser = p.chromium.launch()
        _, result, protos, failed, _ = load(browser, "https://localhost:%d/" % port)
        check_result(result, failed, "h2", "http2WebSockets = false", ws_proto="http/1.1")
        print("ok  Chromium with http2WebSockets = false: the page over h2, the WebSocket on its own HTTP/1.1 connection")
        browser.close()
finally:
    srv.terminate()
    try:
        err = srv.communicate(timeout=10)[1].decode(errors="replace")
    except subprocess.TimeoutExpired:
        srv.kill()
        err = ""
    # Chromium rejects the self-signed certificate on its side connections before honoring
    # ignore_https_errors: those lines are expected here; anything else is worth showing
    unexpected = [l for l in err.splitlines() if l.startswith("vela:") and "certificate unknown" not in l
                  and "warning: a handler held the worker" not in l]
    if unexpected:
        print("server log:\n" + "\n".join(unexpected))
print("all real-browser checks passed")
