/// Server for the real-browser test (`tests/net/browser_test.py`): an HTML page that loads static
/// assets (including a 2 MiB script), calls a JSON API with GET and POST, over HTTPS with the
/// cleartext redirect port. Usage: browser_serve <port> <redirectPort> <cert.pem> <key.pem> <publicDir>
module browser_serve;

import vela;

@safe:

struct Item
{
    long id;
    string name;
}

struct NewItem
{
    @minLength(1) string name;
}

Item getItem(long id) => Item(id, "item " ~ idToString(id));

WithStatus!Item createItem(JsonBody!NewItem body) => WithStatus!Item(201, Item(99, body.value.name));

string proto(Context c) => c.request.protocol == Protocol.http2 ? "h2" : "http/1.1";

Response page() => Response.html(`<!doctype html>
<html><head><meta charset="utf-8"><title>vela</title>
<link rel="stylesheet" href="/static/style.css">
</head><body>
<h1 id="title">loading</h1>
<div id="imgs"></div>
<script src="/static/big.js"></script>
<script>
(async () => {
  const imgs = document.getElementById('imgs');
  await Promise.all(Array.from({length: 24}, (_, i) => new Promise((ok, fail) => {
    const im = new Image(); im.onload = ok; im.onerror = fail; im.src = '/static/img' + i + '.svg'; imgs.appendChild(im);
  })));
  const item = await (await fetch('/api/items/7')).json();
  const created = await fetch('/api/items', {method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({name: 'from the browser'})});
  const made = await created.json();
  const proto = await (await fetch('/api/proto')).text();
  window.result = {item, status: created.status, made, proto, bigOk: window.bigOk === true};
  document.getElementById('title').textContent = 'done';
})().catch(e => { window.result = {error: String(e)}; });
</script>
</body></html>`);

string idToString(long id)
{
    import std.conv : to;

    return id.to!string;
}

void main(string[] args) @system
{
    import std.conv : to;

    auto app = new App;
    app.get!("/", page);
    app.get!("/api/items/{id}", getItem);
    app.post!("/api/items", createItem);
    app.get!("/api/proto", proto);
    app.serveStatic("/static", args[5]);
    ServerConfig cfg;
    cfg.port = args[1].to!ushort;
    cfg.host = "127.0.0.1";
    cfg.workers = 2;
    cfg.tls.certFile = args[3];
    cfg.tls.keyFile = args[4];
    cfg.tls.redirectPort = args[2].to!ushort;
    serve(app, cfg);
}
