"""WebSocket interop with the python `websockets` library (tools/ws_interop.sh).

Usage: ws_interop.py client <port>   -- talks to tests/net/ws_serve.d as a client
       ws_interop.py server <port>   -- serves an echo for vela's WebSocket client (tests/net/ws_client_check.d)
Exits 77 when `websockets` is not installed.
"""
import asyncio
import os
import sys

try:
    import websockets
    from websockets.asyncio.client import connect
    from websockets.asyncio.server import serve
except ImportError:
    print("skip: python3 websockets (>= 13) not installed", file=sys.stderr)
    sys.exit(77)

failures = 0


def check(cond, label):
    global failures
    if cond:
        print(f"ok  {label}")
    else:
        failures += 1
        print(f"FAILED: {label}")


async def client(port):
    base = f"ws://127.0.0.1:{port}"
    for path, compression in (("/echo", None), ("/echo-z", "deflate"), ("/echo", "deflate")):
        async with connect(base + path, compression=compression, max_size=32 << 20) as ws:
            ext = ws.response.headers.get("Sec-WebSocket-Extensions")
            label = f"{path} (client offers {compression or 'nothing'}, server answered {ext or 'no extension'})"
            if path == "/echo-z" and compression:
                check(ext is not None and ext.startswith("permessage-deflate"), f"{label}: deflate negotiated")
            else:
                check(ext is None, f"{label}: no extension")
            await ws.send("hello")
            check(await ws.recv() == "hello", f"{label}: text echo")
            await ws.send("çãõ €" * 1000)
            check(await ws.recv() == "çãõ €" * 1000, f"{label}: UTF-8 text echo (compressible)")
            blob = os.urandom(3 << 20)
            await ws.send(blob)
            check(await ws.recv() == blob, f"{label}: 3 MiB random binary echo")
            for i in range(50):
                await ws.send(f"message {i} " + "x" * i)
            got = [await ws.recv() for _ in range(50)]
            check(got == [f"message {i} " + "x" * i for i in range(50)], f"{label}: 50 messages in order")
            pong = await ws.ping(b"tick")
            await asyncio.wait_for(pong, 5)
            check(True, f"{label}: ping answered")
            await ws.close(1000, "bye")
            check(ws.close_code == 1000, f"{label}: close handshake (code {ws.close_code})")

    async with connect(base + "/burst/40", compression="deflate") as ws:
        got = []
        try:
            while True:
                got.append(await ws.recv())
        except websockets.ConnectionClosed as e:
            check(e.rcvd is not None and e.rcvd.code == 4000 and e.rcvd.reason == "done",
                  f"/burst/40: the server closes with 4000 ({e.rcvd})")
        check(len(got) == 40 and all(len(m) == i * 100 + 1 for i, m in enumerate(got)), "/burst/40: 40 compressed messages")

    try:
        async with connect(base + "/ready") as ws:
            check(False, "a plain GET route refuses the upgrade")
    except websockets.InvalidStatus as e:
        check(e.response.status_code == 200, f"a WebSocket to a plain GET route is not upgraded ({e.response.status_code})")
    return failures


async def server(port):
    async def echo(ws):
        async for m in ws:
            await ws.send(m)

    async with serve(echo, "127.0.0.1", port, compression="deflate", max_size=32 << 20):
        print("ready", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    mode, port = sys.argv[1], int(sys.argv[2])
    if mode == "client":
        sys.exit(1 if asyncio.run(client(port)) else 0)
    asyncio.run(server(port))
