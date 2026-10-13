#!/usr/bin/env python3
"""Real browser against vela (Chromium through Playwright): loads a page over HTTPS with 26 static
assets and three API calls, checks the protocol Chromium negotiated for every resource (h2 by
default, http/1.1 with HTTP/2 disabled), follows the redirect from the cleartext port, and checks a
2 MiB script arrives intact. Usage: browser_test.py <server binary>. Exits 0 with a warning when
Playwright or Chromium is not available."""
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
    print("warning: python playwright not installed; skipping the real-browser test")
    sys.exit(0)

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
    print("warning: the openssl command failed; skipping the real-browser test")
    sys.exit(0)

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

    def check_result(result, failed, proto, label):
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

    with sync_playwright() as p:
        try:
            browser = p.chromium.launch()
        except Exception as e:  # no browser binary
            print("warning: Chromium could not start (%s); skipping the real-browser test" % str(e).splitlines()[0])
            sys.exit(0)
        version = browser.version

        resp, result, protos, failed, _ = load(browser, "https://localhost:%d/" % port)
        if resp.status != 200:
            fail("page status %d" % resp.status)
        check_result(result, failed, "h2", "HTTP/2")
        if len(protos) < 29 or any(x != "h2" for x in protos):
            fail("expected h2 for every resource, got %s" % protos)
        print("ok  Chromium %s over HTTPS: page, 26 assets (2 MiB script) and 3 API calls, all h2" % version)

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
