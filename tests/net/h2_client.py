#!/usr/bin/env python3
"""HTTP/2 interoperability with an independent implementation (python-h2, the library behind
httpx/hyper). Usage: h2_client.py <port> [ca.pem]: with a CA, HTTPS with ALPN (Python's ssl
module, i.e. OpenSSL as a client). Exits non-zero on the first failure."""
import socket
import ssl
import sys
import time

import h2.config
import h2.connection
import h2.events

PORT = int(sys.argv[1])
CA = sys.argv[2] if len(sys.argv) > 2 else None


class Conn:
    def __init__(self, upgrade=False):
        self.sock = socket.create_connection(("127.0.0.1", PORT), timeout=10)
        if CA:
            ctx = ssl.create_default_context(cafile=CA)
            ctx.set_alpn_protocols(["h2", "http/1.1"])
            self.sock = ctx.wrap_socket(self.sock, server_hostname="localhost")
            assert self.sock.selected_alpn_protocol() == "h2", self.sock.selected_alpn_protocol()
        self.h2 = h2.connection.H2Connection(h2.config.H2Configuration(client_side=True))
        self.responses = {}
        if upgrade:
            settings = self.h2.initiate_upgrade_connection()
            self.sock.sendall(b"GET /proto HTTP/1.1\r\nHost: up\r\nConnection: Upgrade, HTTP2-Settings\r\n"
                              b"Upgrade: h2c\r\nHTTP2-Settings: " + settings + b"\r\n\r\n")
            head = b""
            while b"\r\n\r\n" not in head:
                head += self.sock.recv(1)
            assert head.startswith(b"HTTP/1.1 101"), head
            self.responses[1] = {"headers": None, "body": b"", "done": False, "reset": None}
        else:
            self.h2.initiate_connection()
        self.flush()

    def flush(self):
        data = self.h2.data_to_send()
        if data:
            self.sock.sendall(data)

    def request(self, method, path, body=b"", headers=()):
        sid = self.h2.get_next_available_stream_id()
        hs = [(":method", method), (":path", path), (":scheme", "http"), (":authority", "interop")]
        hs += list(headers)
        if body:
            hs.append(("content-length", str(len(body))))
        self.h2.send_headers(sid, hs, end_stream=not body)
        self.responses[sid] = {"headers": None, "body": b"", "done": False, "reset": None}
        if body:
            # respect the server's flow-control window, as a real client must
            while body:
                self.flush()
                window = min(self.h2.local_flow_control_window(sid), self.h2.max_outbound_frame_size)
                if window <= 0:
                    self.read_once()
                    continue
                chunk, body = body[:window], body[window:]
                self.h2.send_data(sid, chunk, end_stream=not body)
        self.flush()
        return sid

    def read_once(self):
        data = self.sock.recv(65536)
        if not data:
            raise ConnectionError("server closed the connection")
        for ev in self.h2.receive_data(data):
            if isinstance(ev, h2.events.ResponseReceived):
                self.responses[ev.stream_id]["headers"] = dict(ev.headers)
            elif isinstance(ev, h2.events.DataReceived):
                self.responses[ev.stream_id]["body"] += ev.data
                self.h2.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
            elif isinstance(ev, h2.events.StreamEnded):
                self.responses[ev.stream_id]["done"] = True
            elif isinstance(ev, h2.events.StreamReset):
                self.responses[ev.stream_id]["reset"] = ev.error_code
                self.responses[ev.stream_id]["done"] = True
        self.flush()

    def wait(self, *sids):
        while not all(self.responses[s]["done"] for s in sids):
            self.read_once()
        return [self.responses[s] for s in sids]


LABEL = "python-h2 (TLS)" if CA else "python-h2"


def check(name, cond):
    if not cond:
        print("FAILED:", LABEL, name)
        sys.exit(1)
    print("ok ", LABEL + ":", name)


c = Conn()
(r,) = c.wait(c.request("GET", "/"))
check("GET /", r["headers"][b":status"] == b"200" and r["body"] == b"hello from andaime")

payload = bytes(range(256)) * 4000  # ~1 MB, more than every initial window
(r,) = c.wait(c.request("POST", "/echo", payload))
check("1 MB upload echoed back intact (flow control both ways)", r["body"] == payload)

t0 = time.monotonic()
ids = [c.request("GET", "/nap/300") for _ in range(60)]
rs = c.wait(*ids)
ms = (time.monotonic() - t0) * 1000
check("60 concurrent streams of 300 ms in %.0f ms" % ms, all(r["body"] == b"slept" for r in rs) and ms < 1500)

(r,) = c.wait(c.request("GET", "/big/2048"))
expected = bytes(97 + i % 26 for i in range(2048 * 1024))
check("2 MiB response intact", r["body"] == expected)

(r,) = c.wait(c.request("GET", "/missing"))
check("404", r["headers"][b":status"] == b"404")

if not CA:
    up = Conn(upgrade=True)
    (r,) = up.wait(1)
    check("h2c upgrade answers the HTTP/1.1 request on stream 1", r["body"] == b"h2")
    (r,) = up.wait(up.request("GET", "/"))
    check("upgraded connection serves new streams", r["body"] == b"hello from andaime")
else:
    (r,) = c.wait(c.request("GET", "/proto"))
    check("ALPN h2 reaches the handler as HTTP/2", r["body"] == b"h2")

c.h2.close_connection()
c.flush()
print("all", LABEL, "interop checks passed")
