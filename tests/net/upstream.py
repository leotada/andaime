#!/usr/bin/env python3
"""HTTP/HTTPS helper server for vela's HTTP client tests.

Uso: upstream.py <cert.pem> <key.pem>
Prints "PLAIN <port> TLS <port>" on standard output when ready.
Rotas: /hello, /chunked, /close, /stale, /slow/<ms>, /echo (POST), /big, /stats
"""
import ssl, sys, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

conns = 0
lock = threading.Lock()

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        global conns
        with lock:
            conns += 1
        super().setup()

    def log_message(self, *a):
        pass

    def send_body(self, body, extra=()):
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path
        if p == "/hello":
            self.send_body(b"hello")
        elif p == "/chunked":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for part in (b"abc", b"defgh", b"i" * 300):
                self.wfile.write(b"%x\r\n" % len(part) + part + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        elif p == "/close":
            self.send_response(200)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"until-close")
            self.close_connection = True
        elif p == "/stale":
            self.send_body(b"stale-ok")
            self.close_connection = True  # closes the socket without warning
        elif p.startswith("/slow/"):
            time.sleep(int(p[6:]) / 1000)
            self.send_body(b"slow-done")
        elif p.startswith("/latest"):
            if "base=ERR" in p:
                self.send_response(500)
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                base = p.split("base=")[-1] if "base=" in p else "USD"
                self.send_body(('{"base":"%s","rates":{"BRL":5.1}}' % base).encode(),
                               [("Content-Type", "application/json")])
        elif p == "/big":
            self.send_body(b"x" * (3 << 20))
        elif p == "/stats":
            with lock:
                self.send_body(str(conns).encode())
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(n)
        ct = self.headers.get("Content-Type", "-")
        self.send_body(b"echo:" + ct.encode() + b":" + data)

class S(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 512

plain = S(("127.0.0.1", 0), H)
tls = S(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[1], sys.argv[2])
tls.socket = ctx.wrap_socket(tls.socket, server_side=True)
for s in (plain, tls):
    threading.Thread(target=s.serve_forever, daemon=True).start()
print("PLAIN %d TLS %d" % (plain.server_address[1], tls.server_address[1]), flush=True)
threading.Event().wait()
