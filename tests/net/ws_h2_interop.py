#!/usr/bin/env python3
"""WebSockets over HTTP/2 (RFC 8441) against tests/net/ws_serve.d, with independent implementations: python-h2 for the
HTTP/2 connection and the `websockets` library's frame codec and permessage-deflate for what travels in the stream.

Usage: ws_h2_interop.py <port> [ca.pem]   -- with a CA, HTTPS with ALPN h2; otherwise h2c with prior knowledge.
Exits 77 when h2 or websockets (>= 13) is missing, 1 on the first failure.
"""
import os
import socket
import ssl
import sys

try:
    import h2.config
    import h2.connection
    import h2.events
    import h2.settings
    from websockets.extensions.permessage_deflate import ClientPerMessageDeflateFactory
    from websockets.frames import Close, Frame, Opcode
    from websockets.headers import parse_extension
    from websockets.streams import StreamReader
except ImportError as e:
    print(f"skip: python module missing ({e.name}; pip install h2 websockets)", file=sys.stderr)
    sys.exit(77)

PORT = int(sys.argv[1])
CA = sys.argv[2] if len(sys.argv) > 2 else None
SCHEME = "https" if CA else "http"


def fail(msg):
    print(f"FAILED: {msg}")
    sys.exit(1)


class Conn:
    """One HTTP/2 connection; several streams can be open on it."""

    def __init__(self):
        self.sock = socket.create_connection(("127.0.0.1", PORT), timeout=10)
        if CA:
            ctx = ssl.create_default_context(cafile=CA)
            ctx.set_alpn_protocols(["h2", "http/1.1"])
            self.sock = ctx.wrap_socket(self.sock, server_hostname="localhost")
            if self.sock.selected_alpn_protocol() != "h2":
                fail(f"ALPN chose {self.sock.selected_alpn_protocol()}")
        self.h2 = h2.connection.H2Connection(h2.config.H2Configuration(client_side=True))
        self.h2.initiate_connection()
        self.flush()
        self.streams = {}  # id -> {"headers", "data" (bytearray), "ended", "reset"}
        self.connect_protocol = None
        while self.connect_protocol is None:
            self.pump()

    def flush(self):
        out = self.h2.data_to_send()
        if out:
            self.sock.sendall(out)

    def pump(self):
        data = self.sock.recv(65536)
        if not data:
            fail("the server closed the connection")
        for ev in self.h2.receive_data(data):
            if isinstance(ev, h2.events.RemoteSettingsChanged):
                c = ev.changed_settings.get(h2.settings.SettingCodes.ENABLE_CONNECT_PROTOCOL)
                self.connect_protocol = c.new_value if c else 0
            elif isinstance(ev, h2.events.ResponseReceived):
                self.streams[ev.stream_id]["headers"] = dict(ev.headers)
            elif isinstance(ev, h2.events.DataReceived):
                self.streams[ev.stream_id]["data"] += ev.data
                self.h2.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
            elif isinstance(ev, h2.events.StreamEnded):
                self.streams[ev.stream_id]["ended"] = True
            elif isinstance(ev, h2.events.StreamReset):
                self.streams[ev.stream_id]["reset"] = ev.error_code
        self.flush()

    def open(self, headers, end_stream=False):
        sid = self.h2.get_next_available_stream_id()
        self.streams[sid] = {"headers": None, "data": bytearray(), "ended": False, "reset": None}
        self.h2.send_headers(sid, headers, end_stream=end_stream)
        self.flush()
        return sid

    def response(self, sid):
        st = self.streams[sid]
        while st["headers"] is None and st["reset"] is None:
            self.pump()
        return st

    def get(self, path):
        sid = self.open([(":method", "GET"), (":scheme", SCHEME), (":path", path), (":authority", "localhost")], True)
        st = self.response(sid)
        while not st["ended"]:
            self.pump()
        return st["headers"][b":status"], bytes(st["data"])

    def send_data(self, sid, data, end_stream=False):
        while data:
            window = self.h2.local_flow_control_window(sid)
            if window == 0:
                self.pump()
                continue
            n = min(window, self.h2.max_outbound_frame_size, len(data))
            self.h2.send_data(sid, data[:n])
            data = data[n:]
            self.flush()
        if end_stream:
            self.h2.end_stream(sid)
            self.flush()


class WebSocket:
    """A WebSocket on one stream of `Conn`: the frames are the `websockets` library's own."""

    def __init__(self, conn, path, deflate=False, extra=()):
        self.conn = conn
        headers = [(":method", "CONNECT"), (":protocol", "websocket"), (":scheme", SCHEME), (":path", path),
                   (":authority", "localhost"), ("sec-websocket-version", "13")]
        factory = ClientPerMessageDeflateFactory()
        if deflate:
            headers.append(("sec-websocket-extensions", "permessage-deflate; client_max_window_bits"))
        headers += list(extra)
        self.sid = conn.open(headers)
        st = conn.response(self.sid)
        self.status = int(st["headers"][b":status"]) if st["headers"] else None
        self.headers = st["headers"] or {}
        self.extensions = []
        ext = self.headers.get(b"sec-websocket-extensions")
        if ext:
            name, params = parse_extension(ext.decode())[0]
            self.extensions = [factory.process_response_params(params, [])]
        self.reader = StreamReader()
        self.used = 0

    def send(self, opcode, payload):
        frame = Frame(opcode, payload)
        self.conn.send_data(self.sid, frame.serialize(mask=True, extensions=self.extensions))

    def send_text(self, s):
        self.send(Opcode.TEXT, s.encode())

    def recv_frame(self):
        st = self.conn.streams[self.sid]
        while True:
            fresh = st["data"][self.used:]
            if fresh:
                self.reader.feed_data(bytes(fresh))
                self.used += len(fresh)
            parser = Frame.parse(self.reader.read_exact, mask=False, max_size=64 << 20, extensions=self.extensions)
            try:
                # the reader is not consumed until a whole frame is there: try, and feed more on StopIteration's absence
                snapshot = bytes(self.reader.buffer)
                next(parser)
            except StopIteration as done:
                return done.value
            self.reader.buffer[:0] = snapshot[: len(snapshot) - len(self.reader.buffer)]  # put it back
            if st["ended"] or st["reset"] is not None:
                return None
            self.conn.pump()

    def recv(self):
        """The next data message (reassembled), or ("close", code, reason) / None at the end of the stream."""
        parts, op = [], None
        while True:
            f = self.recv_frame()
            if f is None:
                return None
            if f.opcode == Opcode.PING:
                self.send(Opcode.PONG, f.data)
                continue
            if f.opcode == Opcode.PONG:
                return ("pong", f.data)
            if f.opcode == Opcode.CLOSE:
                c = Close.parse(f.data)
                return ("close", c.code, c.reason)
            if f.opcode in (Opcode.TEXT, Opcode.BINARY):
                op = f.opcode
            parts.append(f.data)
            if f.fin:
                data = b"".join(parts)
                return data.decode() if op == Opcode.TEXT else data

    def close(self, code=1000, reason=""):
        self.send(Opcode.CLOSE, Close(code, reason).serialize())
        answer = self.recv()
        self.conn.send_data(self.sid, b"", end_stream=True)
        st = self.conn.streams[self.sid]
        while not st["ended"] and st["reset"] is None:
            self.conn.pump()
        return answer, st


def check(cond, label):
    if not cond:
        fail(label)
    print(f"ok  {label}")


def main():
    mode = "h2 over TLS" if CA else "h2c"
    c = Conn()
    check(c.connect_protocol == 1, f"{mode}: the server announces SETTINGS_ENABLE_CONNECT_PROTOCOL")

    for path, deflate in (("/echo", False), ("/echo-z", True)):
        ws = WebSocket(c, path, deflate)
        label = f"{mode} {path}" + (" (permessage-deflate)" if deflate else "")
        check(ws.status == 200 and b"sec-websocket-accept" not in ws.headers, f"{label}: 200, no Sec-WebSocket-Accept")
        check(bool(ws.extensions) == deflate, f"{label}: extension negotiated = {deflate}")
        ws.send_text("hello")
        check(ws.recv() == "hello", f"{label}: text echo")
        ws.send_text("çãõ €" * 1000)
        check(ws.recv() == "çãõ €" * 1000, f"{label}: UTF-8 text echo")
        blob = os.urandom(3 << 20)
        ws.send(Opcode.BINARY, blob)
        check(ws.recv() == blob, f"{label}: 3 MiB binary echo (many stream windows both ways)")
        for i in range(50):
            ws.send_text(f"message {i} " + "x" * i)
        got = [ws.recv() for _ in range(50)]
        check(got == [f"message {i} " + "x" * i for i in range(50)], f"{label}: 50 messages in order")
        ws.send(Opcode.PING, b"tick")
        check(ws.recv() == ("pong", b"tick"), f"{label}: ping answered")
        answer, st = ws.close(1000, "bye")
        check(answer == ("close", 1000, ""), f"{label}: close handshake ({answer})")
        check(st["ended"] and st["reset"] is None, f"{label}: the server ended the stream with END_STREAM")

    # two WebSockets and ordinary requests multiplexed on the same connection
    a, b = WebSocket(c, "/echo"), WebSocket(c, "/echo")
    a.send_text("to a")
    b.send_text("to b")
    status, body = c.get("/ready")
    check(status == b"200" and body == b"ok", f"{mode}: a GET between two open WebSockets")
    check(b.recv() == "to b" and a.recv() == "to a", f"{mode}: two WebSockets on one connection")

    # the client resets one of them: the server's side ends (1006 for its handler), the other one and the connection live
    c.h2.reset_stream(a.sid)
    c.flush()
    b.send_text("still here")
    check(b.recv() == "still here", f"{mode}: a reset WebSocket does not disturb its neighbour")
    answer, _ = b.close()
    check(answer == ("close", 1000, ""), f"{mode}: the neighbour closes cleanly")

    # the server closes first (4000 after 40 compressed messages)
    ws = WebSocket(c, "/burst/40", deflate=True)
    msgs = [ws.recv() for _ in range(40)]
    check(all(len(m) == i * 100 + 1 for i, m in enumerate(msgs)), f"{mode}: 40 server messages")
    check(ws.recv() == ("close", 4000, "done"), f"{mode}: the server's close frame")
    ws.send(Opcode.CLOSE, Close(4000, "").serialize())
    c.send_data(ws.sid, b"", end_stream=True)
    st = c.streams[ws.sid]
    while not st["ended"] and st["reset"] is None:
        c.pump()
    check(st["ended"], f"{mode}: the server ended the stream after its close")

    # refusals are HTTP answers on the stream
    no = WebSocket(c, "/ready")
    check(no.status == 400, f"{mode}: an extended CONNECT on an ordinary route gets 400 ({no.status})")
    bad = WebSocket(c, "/echo", extra=[("x", "1")])
    check(bad.status == 200, f"{mode}: extra headers are fine")
    bad.close()
    status, body = c.get("/ready")
    check(status == b"200", f"{mode}: the connection still serves requests")


main()
