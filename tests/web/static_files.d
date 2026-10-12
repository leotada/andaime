/// Arquivos estáticos: conteúdo, ETag/304, index, traversal e links simbólicos.
module static_files;

import vela;
import vela.web.testing;
import core.stdc.stdio : tmpfile;
import std.file : mkdirRecurse, write, symlink, tempDir, rmdirRecurse, exists;
import std.path : buildPath;

unittest
{
    auto base = buildPath(tempDir, "vela_static_test");
    if (exists(base))
        rmdirRecurse(base);
    mkdirRecurse(buildPath(base, "pub", "css"));
    mkdirRecurse(buildPath(base, "pub", ".git"));
    write(buildPath(base, "pub", "index.html"), "<h1>oi</h1>");
    write(buildPath(base, "pub", "css", "app.css"), "body{}");
    write(buildPath(base, "pub", "css", "index.html"), "css-index");
    write(buildPath(base, "pub", ".git", "config"), "segredo");
    write(buildPath(base, "pub", "a b.txt"), "com espaco");
    write(buildPath(base, "fora.txt"), "FORA");
    symlink(buildPath(base, "fora.txt"), buildPath(base, "pub", "link.txt"));
    write(buildPath(base, "pub", "big.bin"), new ubyte[600_000]);
    scope (exit)
        rmdirRecurse(base);

    auto app = new App;
    app.get!("/api", () => "api");
    app.serveStatic("/assets", buildPath(base, "pub"));
    app.serveStatic("", buildPath(base, "pub")); // raiz do site
    auto c = TestClient(app);

    auto r = c.get("/assets/css/app.css");
    assert(r.status == 200 && r.body == "body{}" && r.contentType == "text/css; charset=utf-8");
    assert(r.header("Cache-Control") == "public, max-age=3600");
    auto etag = r.header("ETag");
    assert(etag.length > 4 && etag[0 .. 3] == `W/"`);
    assert(r.header("Last-Modified").length == 29);

    // 304 com If-None-Match
    r = c.get("/assets/css/app.css", hdr("If-None-Match", etag));
    assert(r.status == 304 && r.body.length == 0);
    r = c.get("/assets/css/app.css", hdr("If-None-Match", `"outro"`));
    assert(r.status == 200);

    // index de pastas
    assert(c.get("/assets").body == "<h1>oi</h1>");
    assert(c.get("/assets/").status == 404 || c.get("/assets/").status == 200);
    assert(c.get("/assets/css").body == "css-index");
    assert(c.get("/").body == "<h1>oi</h1>");
    assert(c.get("/api").body == "api"); // rota normal convive com a raiz estática

    // percent-encoding
    assert(c.get("/assets/a%20b.txt").body == "com espaco");

    // ataques
    foreach (bad; ["/assets/../fora.txt", "/assets/%2e%2e/fora.txt", "/assets/css/../../fora.txt",
        "/assets/%2e%2e%2ffora.txt", "/assets/.git/config", "/assets/link.txt", "/assets/nada",
        "/assets/a%00b", "/assets/css%5c..%5c..%5cfora.txt"])
    {
        auto x = c.get(bad);
        assert(x.status == 404, bad);
        assert(x.body.length < 60 && x.body != "FORA" && x.body != "segredo", bad);
    }

    // arquivo grande (caminho do offload, inline no TestClient)
    r = c.get("/assets/big.bin");
    assert(r.status == 200 && r.body.length == 600_000 && r.contentType == "application/octet-stream");
}
