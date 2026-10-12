#!/usr/bin/env python3
"""End-to-end test of the examples/api example (running for real, with Postgres and an upstream).
Usage: api_e2e.py <port> <token>"""
import json, sys, threading, urllib.request, urllib.error

port, token = sys.argv[1], sys.argv[2]
base = f"http://127.0.0.1:{port}"
fails = 0

def call(method, path, body=None, headers=None, auth=True, follow=False):
    h = dict(headers or {})
    if auth:
        h["Authorization"] = "Bearer " + token
    data = None
    if body is not None:
        data = json.dumps(body).encode() if not isinstance(body, bytes) else body
        h.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(base + path, data=data, method=method, headers=h)
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k): return None
    opener = urllib.request.build_opener() if follow else urllib.request.build_opener(NoRedirect)
    try:
        r = opener.open(req, timeout=10)
        return r.status, r.read().decode(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), dict(e.headers)

def check(name, cond, extra=""):
    global fails
    if cond:
        print("ok  " + name)
    else:
        fails += 1
        print("FAILED " + name, extra)

s, b, h = call("GET", "/health", auth=False)
check("health without a token", s == 200 and b == "ok" and len(h.get("X-Request-Id", "")) == 16)
s, b, h = call("GET", "/health", auth=False, headers={"X-Request-Id": "my-id-1"})
check("received X-Request-Id is returned", h.get("X-Request-Id") == "my-id-1")

s, b, h = call("GET", "/api/v1/users", auth=False)
check("no token: 401 + WWW-Authenticate", s == 401 and h.get("WWW-Authenticate") == "Bearer")
s, b, h = call("GET", "/api/v1/users", headers={"Authorization": "Bearer errado"}, auth=False)
check("wrong token: 401", s == 401)
s, b, h = call("GET", "/api/v1/whoami")
check("Local!Caller reaches the handler", s == 200 and b.startswith(token[:4]), b)

# CRUD
s, b, h = call("POST", "/api/v1/users", {"name": "Ana", "email": "ana@x.com", "age": 31})
check("creates a user (201)", s == 201 and json.loads(b)["name"] == "Ana", b)
uid = json.loads(b)["id"] if s == 201 else 0
s, b, h = call("POST", "/api/v1/users", {"name": "Outra Ana", "email": "ana@x.com", "age": 20})
check("duplicate e-mail: 409 (PgError.isUniqueViolation)", s == 409, b)
s, b, h = call("POST", "/api/v1/users", {"name": "A", "email": "a@x.com", "age": 200})
d = json.loads(b) if s == 422 else {}
locs = [tuple(x["loc"]) for x in d.get("detail", [])]
check("invalid body: 422 in FastAPI format", s == 422 and ("body", "name") in locs and ("body", "age") in locs, b)
s, b, h = call("POST", "/api/v1/users", b"{not json")
check("broken JSON: 422", s == 422, b)
s, b, h = call("GET", f"/api/v1/users/{uid}")
check("fetch by id", s == 200 and json.loads(b)["email"] == "ana@x.com", b)
s, b, h = call("GET", "/api/v1/users/999999")
check("nonexistent id: 404", s == 404, b)
s, b, h = call("GET", "/api/v1/users/abc")
check("non-numeric id: 422", s == 422, b)
s, b, h = call("PUT", f"/api/v1/users/{uid}", {"name": "Ana Maria", "email": "ana@x.com", "age": 32})
check("updates", s == 200 and json.loads(b)["name"] == "Ana Maria", b)
s, b, h = call("GET", "/api/v1/users?limit=5&offset=0")
check("list with query", s == 200 and any(u["id"] == uid for u in json.loads(b)), b)
s, b, h = call("GET", "/api/v1/users?limit=500")
check("limit out of range: 422", s == 422, b)
s, b, h = call("DELETE", f"/api/v1/users/{uid}")
check("deletes (204)", s == 204, b)
s, b, h = call("DELETE", f"/api/v1/users/{uid}")
check("delete again: 404", s == 404)

# external API
s, b, h = call("GET", "/api/v1/rates/USD")
check("quote via the outgoing HTTP client", s == 200 and json.loads(b)["rates"]["BRL"] == 5.1, b)
s, b, h = call("GET", "/api/v1/rates/ERR")
check("upstream error becomes 502", s == 502, b)
s, b, h = call("GET", "/api/v1/rates/U$D")
check("invalid currency: 422", s == 422, b)

# static files
s, b, h = call("GET", "/assets/index.html", auth=False)
check("static file", s == 200 and "<h1>vela api</h1>" in b and h.get("ETag"), b)
s, b, h2 = call("GET", "/assets/index.html", auth=False, headers={"If-None-Match": h["ETag"]})
check("static: 304 with ETag", s == 304)
for bad in ["/assets/../dub.sdl", "/assets/%2e%2e/dub.sdl", "/assets/..%2fdub.sdl"]:
    s, b, h = call("GET", bad, auth=False)
    check("traversal blocked " + bad, s == 404 and "vela-pg" not in b, b[:60])

# OpenAPI
s, b, h = call("GET", "/openapi.json", auth=False)
doc = json.loads(b) if s == 200 else {}
check("valid openapi.json with the routes",
      "/api/v1/users" in doc.get("paths", {}) and "post" in doc["paths"]["/api/v1/users"]
      and "User" in doc.get("components", {}).get("schemas", {}), b[:200])
s, b, h = call("GET", "/docs", auth=False)
check("/docs", s == 200 and "swagger" in b.lower())

# trailing slash
s, b, h = call("GET", "/api/v1/users/?limit=3")
check("trailing slash: 308 to the right route", s == 308 and h.get("Location") == "/api/v1/users?limit=3", str(h))

# CORS (the app was started with CORS_ORIGINS)
s, b, h = call("OPTIONS", "/api/v1/users", auth=False,
               headers={"Origin": "https://app.example.com", "Access-Control-Request-Method": "POST"})
check("CORS preflight 204", s == 204 and h.get("Access-Control-Allow-Origin") == "https://app.example.com", str(h))
s, b, h = call("GET", "/health", auth=False, headers={"Origin": "https://mal.com"})
check("CORS unknown origin without headers", "Access-Control-Allow-Origin" not in h)

# concurrent load: 200 requests with 40 threads
errs = []
def worker():
    for _ in range(5):
        s, b, h = call("GET", "/api/v1/users?limit=10")
        if s != 200: errs.append(s)
ts = [threading.Thread(target=worker) for _ in range(40)]
[t.start() for t in ts]; [t.join() for t in ts]
check("200 concurrent listings (40 clients)", not errs, str(errs[:5]))

print("e2e: %s" % ("all good" if fails == 0 else "%d failures" % fails))
sys.exit(1 if fails else 0)
